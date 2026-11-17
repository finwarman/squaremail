use crate::{
    Result,
    mime::message_id,
    model::*,
    network::{self, Context},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use reqwest::blocking::Client;
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
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
type AccountLock = std::sync::Arc<std::sync::Mutex<()>>;
static REFRESH_LOCKS: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashMap<String, std::sync::Weak<std::sync::Mutex<()>>>>,
> = std::sync::LazyLock::new(Default::default);

fn account_lock(id: &str) -> Result<AccountLock> {
    let mut locks = REFRESH_LOCKS
        .lock()
        .map_err(|_| "Credential registry failed")?;
    locks.retain(|_, value| value.strong_count() > 0);
    if let Some(lock) = locks.get(id).and_then(std::sync::Weak::upgrade) {
        return Ok(lock);
    }
    let lock = std::sync::Arc::new(std::sync::Mutex::new(()));
    locks.insert(id.into(), std::sync::Arc::downgrade(&lock));
    Ok(lock)
}

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

fn endpoints(provider: Provider) -> Result<(&'static str, &'static str, &'static str)> {
    match provider {
        Provider::Gmail => Ok((
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://oauth2.googleapis.com/token",
            "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        )),
        Provider::Outlook => Ok((
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            "offline_access https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/User.Read https://graph.microsoft.com/Calendars.Read",
        )),
        Provider::Local => Err("Local mail does not use OAuth".into()),
    }
}

pub(crate) fn connect(
    provider: Provider,
    client_id: &str,
    client_secret: Option<&str>,
    context: &Context<'_>,
) -> Result<Account> {
    let saved = load_client(provider).ok();
    let client_id = if client_id.trim().is_empty() {
        saved.as_ref().map(|v| v.client_id.as_str()).unwrap_or("")
    } else {
        client_id
    };
    if client_id.is_empty() {
        return Err("Configure an OAuth client ID first".into());
    }
    let client_secret = client_secret.filter(|s| !s.is_empty()).or_else(|| {
        saved
            .as_ref()
            .filter(|v| v.client_id == client_id)
            .and_then(|v| v.client_secret.as_deref())
    });
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
        url.query_pairs_mut().extend_pairs([
            ("access_type", "offline"),
            ("prompt", "consent select_account"),
        ]);
    }
    if provider == Provider::Outlook {
        url.query_pairs_mut()
            .append_pair("prompt", "select_account");
    }
    let status = std::process::Command::new("/usr/bin/open")
        .arg(url.as_str())
        .status()?;
    if !status.success() {
        return Err("Could not open the sign-in browser".into());
    }
    let code = wait_for_code(&listener, &state, context)?;
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
    let client = network::client()?;
    let tokens: TokenResponse =
        serde_json::from_value(context.send(client.post(token_endpoint).form(&form))?.value)?;
    let (email, remote) = profile(&client, provider, &tokens.access_token, context)?;
    let account = Account {
        id: message_id(provider.as_str(), &remote),
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
    let lock = account_lock(&account.id)?;
    let _guard = lock.lock().map_err(|_| "Credential lock failed")?;
    context.check()?;
    save_credentials(&account.id, &credentials)?;
    Ok(account)
}

pub(crate) fn access_token(account: &Account, context: &Context<'_>) -> Result<String> {
    // Rotating refresh tokens must not be consumed by concurrent body/sync requests.
    let lock = account_lock(&account.id)?;
    let _guard = lock.lock().map_err(|_| "Credential lock failed")?;
    context.check()?;
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
    let response = context
        .send(network::client()?.post(endpoint).form(&form))
        .map_err(|error| {
            if network::is_status(error.as_ref(), 400) {
                Box::new(network::HttpError {
                    status: 403,
                    retry: 0,
                }) as Box<dyn std::error::Error + Send + Sync>
            } else {
                error
            }
        })?;
    let tokens: TokenResponse = serde_json::from_value(response.value)?;
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

fn profile(
    client: &Client,
    provider: Provider,
    token: &str,
    context: &Context<'_>,
) -> Result<(String, String)> {
    let endpoint = match provider {
        Provider::Gmail => "https://gmail.googleapis.com/gmail/v1/users/me/profile",
        Provider::Outlook => {
            "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName"
        }
        Provider::Local => return Err("Local account has no provider profile".into()),
    };
    let value = context.send(client.get(endpoint).bearer_auth(token))?.value;
    let email = value
        .get("emailAddress")
        .or_else(|| value.get("mail").filter(|v| v.is_string()))
        .or_else(|| value.get("userPrincipalName"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .ok_or("Provider returned no email address")?;
    let remote = if provider == Provider::Outlook {
        value["id"]
            .as_str()
            .ok_or("Provider returned no stable account ID")?
            .to_string()
    } else {
        email.to_lowercase()
    };
    Ok((email, remote))
}

fn wait_for_code(listener: &TcpListener, state: &str, context: &Context<'_>) -> Result<String> {
    let start = Instant::now();
    while start.elapsed() < LOGIN_TIMEOUT {
        context.check()?;
        let (mut stream, _) = match listener.accept() {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        stream.set_nonblocking(false)?;
        stream.set_write_timeout(Some(Duration::from_secs(1)))?;
        let reading = Instant::now();
        let read_budget = Duration::from_secs(3);
        stream.set_read_timeout(Some(read_budget))?;
        let mut bytes = Vec::new();
        let mut part = [0; 1024];
        while bytes.len() < 8192 && !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
            context.check()?;
            let remaining = read_budget.saturating_sub(reading.elapsed());
            if remaining.is_zero() {
                break;
            }
            stream.set_read_timeout(Some(remaining))?;
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

pub(crate) fn disconnect(id: &str) -> Result<()> {
    let lock = account_lock(id)?;
    let _guard = lock.lock().map_err(|_| "Credential lock failed")?;
    match delete_generic_password(KEYCHAIN_SERVICE, id) {
        Ok(()) => Ok(()),
        Err(error) if error.code() == -25300 => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[derive(Deserialize, Serialize)]
struct ClientConfig {
    client_id: String,
    client_secret: Option<String>,
}
fn load_client(provider: Provider) -> Result<ClientConfig> {
    Ok(serde_json::from_slice(&get_generic_password(
        KEYCHAIN_SERVICE,
        &format!("client:{}", provider.as_str()),
    )?)?)
}
pub(crate) fn client_config(provider: Provider) -> Value {
    match load_client(provider) {
        Ok(v) => serde_json::json!({"client_id":v.client_id,"configured":true}),
        Err(_) => serde_json::json!({"client_id":"","configured":false}),
    }
}
pub(crate) fn configure(provider: Provider, id: &str, secret: Option<&str>) -> Result<()> {
    if provider == Provider::Local || id.trim().is_empty() {
        return Err("Enter a provider client ID".into());
    }
    let config = ClientConfig {
        client_id: id.trim().into(),
        client_secret: secret.filter(|s| !s.is_empty()).map(String::from),
    };
    set_generic_password(
        KEYCHAIN_SERVICE,
        &format!("client:{}", provider.as_str()),
        &serde_json::to_vec(&config)?,
    )?;
    Ok(())
}
pub(crate) fn import_client(path: &str) -> Result<()> {
    let mut raw = Vec::new();
    std::fs::File::open(path)?
        .take(65537)
        .read_to_end(&mut raw)?;
    if raw.len() > 65536 {
        return Err("OAuth configuration file is too large".into());
    }
    let value: Value = serde_json::from_slice(&raw)?;
    let config = &value["installed"];
    let id = config["client_id"]
        .as_str()
        .filter(|v| v.ends_with(".apps.googleusercontent.com"))
        .ok_or("Choose a Google Desktop app JSON file")?;
    configure(Provider::Gmail, id, config["client_secret"].as_str())
}

pub(crate) fn invalidate(account: &Account) -> Result<()> {
    let lock = account_lock(&account.id)?;
    let _guard = lock.lock().map_err(|_| "Credential lock failed")?;
    let raw = get_generic_password(KEYCHAIN_SERVICE, &account.id)?;
    let mut credentials: Credentials = serde_json::from_slice(&raw)?;
    credentials.expires_at = 0;
    save_credentials(&account.id, &credentials)
}
pub(crate) fn verify_refresh(account: &Account, context: &Context<'_>) -> Result<()> {
    invalidate(account)?;
    let token = access_token(account, context)?;
    let (_, remote) = profile(&network::client()?, account.provider, &token, context)?;
    if message_id(account.provider.as_str(), &remote) != account.id {
        return Err("Refreshed identity did not match the account".into());
    }
    Ok(())
}
