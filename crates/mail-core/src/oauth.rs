use crate::{Result, mime::message_id, model::*};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use reqwest::blocking::Client;
use security_framework::passwords::{get_generic_password, set_generic_password};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    net::TcpListener,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use url::Url;

const KEYCHAIN_SERVICE: &str = "com.finwarman.squaremail.oauth";
const LOGIN_TIMEOUT: Duration = Duration::from_secs(180);
const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_RESPONSE: u64 = 20 * 1024 * 1024;
static REFRESH_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<u64>,
}

#[derive(Deserialize, Serialize)]
struct Credentials {
    provider: Provider,
    client_id: String,
    client_secret: Option<String>,
    access_token: String,
    refresh_token: Option<String>,
    expires_at: u64,
}

pub(crate) fn http() -> Result<Client> {
    Ok(Client::builder()
        .timeout(HTTP_TIMEOUT)
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("SquareMail/0.1")
        .build()?)
}

pub(crate) fn read_json(response: reqwest::blocking::Response) -> Result<Value> {
    let status = response.status();
    if !status.is_success() {
        return Err(format!(
            "Provider returned HTTP {}. Check sign-in, consent and network access.",
            status.as_u16()
        )
        .into());
    }
    let mut raw = Vec::new();
    response.take(MAX_RESPONSE + 1).read_to_end(&mut raw)?;
    if raw.len() as u64 > MAX_RESPONSE {
        return Err("Provider response exceeded the size limit".into());
    }
    Ok(serde_json::from_slice(&raw)?)
}

fn endpoints(provider: Provider) -> Result<(&'static str, &'static str, &'static str)> {
    match provider {
        Provider::Gmail => Ok((
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://oauth2.googleapis.com/token",
            "https://www.googleapis.com/auth/gmail.readonly",
        )),
        Provider::Outlook => Ok((
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "offline_access https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read",
        )),
        Provider::Local => Err("Local mail does not use OAuth".into()),
    }
}

pub(crate) fn connect(
    provider: Provider,
    client_id: &str,
    client_secret: Option<&str>,
) -> Result<Account> {
    if client_id.trim().is_empty() {
        return Err("Enter an OAuth client ID first".into());
    }
    let (authorize, token_endpoint, scopes) = endpoints(provider)?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let host = if provider == Provider::Outlook {
        "localhost"
    } else {
        "127.0.0.1"
    };
    let redirect = format!("http://{host}:{}/callback", listener.local_addr()?.port());
    let verifier = random_token();
    let state = random_token();
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut url = Url::parse(authorize)?;
    url.query_pairs_mut().extend_pairs([
        ("client_id", client_id),
        ("redirect_uri", &redirect),
        ("response_type", "code"),
        ("scope", scopes),
        ("state", &state),
        ("code_challenge", &challenge),
        ("code_challenge_method", "S256"),
    ]);
    if provider == Provider::Gmail {
        url.query_pairs_mut()
            .extend_pairs([("access_type", "offline"), ("prompt", "consent")]);
    }
    let status = std::process::Command::new("/usr/bin/open")
        .arg(url.as_str())
        .status()?;
    if !status.success() {
        return Err("Could not open the sign-in browser".into());
    }
    let code = wait_for_code(&listener, &state)?;
    let mut form = vec![
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("redirect_uri", &redirect),
        ("code", &code),
        ("code_verifier", &verifier),
    ];
    if let Some(secret) = client_secret.filter(|s| !s.is_empty()) {
        form.push(("client_secret", secret));
    }
    let client = http()?;
    let tokens: TokenResponse =
        serde_json::from_value(read_json(client.post(token_endpoint).form(&form).send()?)?)?;
    let email = profile(&client, provider, &tokens.access_token)?;
    let account = Account {
        id: message_id(provider.as_str(), &email.to_lowercase()),
        email,
        provider,
    };
    let credentials = Credentials {
        provider,
        client_id: client_id.into(),
        client_secret: client_secret.map(String::from),
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: now() + tokens.expires_in.unwrap_or(3600),
    };
    save_credentials(&account.id, &credentials)?;
    Ok(account)
}

pub(crate) fn access_token(account: &Account) -> Result<String> {
    // Rotating refresh tokens must not be consumed by concurrent body/sync requests.
    let _guard = REFRESH_LOCK.lock().map_err(|_| "Credential lock failed")?;
    let raw = get_generic_password(KEYCHAIN_SERVICE, &account.id)
        .map_err(|_| "No saved sign-in. Connect this account again.")?;
    let mut credentials: Credentials = serde_json::from_slice(&raw)?;
    if credentials.expires_at > now() + 60 {
        return Ok(credentials.access_token);
    }
    let refresh = credentials
        .refresh_token
        .as_deref()
        .ok_or("Session expired. Connect this account again.")?;
    let (_, endpoint, _) = endpoints(credentials.provider)?;
    let mut form = vec![
        ("grant_type", "refresh_token"),
        ("client_id", &credentials.client_id),
        ("refresh_token", refresh),
    ];
    if let Some(secret) = credentials
        .client_secret
        .as_deref()
        .filter(|s| !s.is_empty())
    {
        form.push(("client_secret", secret));
    }
    let tokens: TokenResponse =
        serde_json::from_value(read_json(http()?.post(endpoint).form(&form).send()?)?)?;
    credentials.access_token = tokens.access_token;
    if tokens.refresh_token.is_some() {
        credentials.refresh_token = tokens.refresh_token;
    }
    credentials.expires_at = now() + tokens.expires_in.unwrap_or(3600);
    save_credentials(&account.id, &credentials)?;
    Ok(credentials.access_token)
}

fn save_credentials(id: &str, value: &Credentials) -> Result<()> {
    set_generic_password(KEYCHAIN_SERVICE, id, &serde_json::to_vec(value)?)?;
    Ok(())
}

fn profile(client: &Client, provider: Provider, token: &str) -> Result<String> {
    let endpoint = match provider {
        Provider::Gmail => "https://gmail.googleapis.com/gmail/v1/users/me/profile",
        Provider::Outlook => "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName",
        Provider::Local => return Err("Local account has no provider profile".into()),
    };
    let value = read_json(client.get(endpoint).bearer_auth(token).send()?)?;
    value
        .get("emailAddress")
        .or_else(|| value.get("mail").filter(|v| v.is_string()))
        .or_else(|| value.get("userPrincipalName"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .ok_or_else(|| "Provider returned no email address".into())
}

fn wait_for_code(listener: &TcpListener, state: &str) -> Result<String> {
    let start = Instant::now();
    while start.elapsed() < LOGIN_TIMEOUT {
        let (mut stream, _) = match listener.accept() {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        let mut bytes = Vec::new();
        let mut part = [0; 1024];
        while bytes.len() < 8192 && !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
            let length = match stream.read(&mut part) {
                Ok(n) => n,
                Err(_) => break,
            };
            if length == 0 {
                break;
            }
            bytes.extend_from_slice(&part[..length]);
        }
        let request = String::from_utf8_lossy(&bytes);
        let result = callback_code(&request, state);
        let text = if result.is_ok() {
            "Sign-in complete. Return to Square Mail."
        } else {
            "Sign-in rejected. Return to Square Mail and try again."
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
            text.len()
        );
        let _ = stream.write_all(response.as_bytes());
        // Ignore unrelated loopback requests. A matching provider error ends this attempt.
        match result {
            Ok(code) => return Ok(code),
            Err(_) if !request.contains(state) => continue,
            Err(error) => return Err(error),
        }
    }
    Err("Sign-in timed out after three minutes".into())
}

fn callback_code(request: &str, state: &str) -> Result<String> {
    let mut first = request.lines().next().unwrap_or("").split_whitespace();
    if first.next() != Some("GET") {
        return Err("Invalid OAuth callback method".into());
    }
    let target = first.next().ok_or("Missing callback path")?;
    let url = Url::parse(&format!("http://127.0.0.1{target}"))?;
    if url.path() != "/callback" {
        return Err("Invalid OAuth callback path".into());
    }
    let values: Vec<_> = url.query_pairs().collect();
    let states: Vec<_> = values.iter().filter(|(k, _)| k == "state").collect();
    if states.len() != 1 || states[0].1 != state {
        return Err("Sign-in state did not match".into());
    }
    if values.iter().any(|(k, _)| k == "error") {
        return Err("Sign-in was declined by the provider".into());
    }
    let codes: Vec<_> = values.iter().filter(|(k, _)| k == "code").collect();
    if codes.len() != 1 || codes[0].1.is_empty() {
        return Err("No unique authorization code".into());
    }
    Ok(codes[0].1.to_string())
}

fn random_token() -> String {
    let mut bytes = [0; 32];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_binds_code_to_login() {
        assert_eq!(
            callback_code(
                "GET /callback?state=expected&code=abc HTTP/1.1\r\n",
                "expected"
            )
            .unwrap(),
            "abc"
        );
        for target in [
            "/callback?state=wrong&code=abc",
            "/callback?code=abc",
            "/callback?state=expected&state=other&code=abc",
            "/callback?state=expected&code=abc&code=def",
            "/other?state=expected&code=abc",
            "/callback?state=expected&error=access_denied",
        ] {
            assert!(callback_code(&format!("GET {target} HTTP/1.1\r\n"), "expected").is_err());
        }
    }
}
