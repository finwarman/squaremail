//! Signed app resources contain desktop application metadata, never account credentials.
use super::{ClientConfig, Provider};
use crate::Result;
use serde::Deserialize;
use std::io::{Read, Write};

const CONFIG_LIMIT: u64 = 4096;

pub(super) fn export(path: &str) -> Result<()> {
    let google = super::load_client(Provider::Gmail)?;
    let microsoft = super::load_client(Provider::Outlook)?;
    let raw = serde_json::to_vec(&serde_json::json!({
        "gmail": google.client_id,
        "outlook": microsoft.client_id,
        "google_desktop_secret": google.client_secret.ok_or("Import the Google Desktop client first")?,
    }))?;
    parse(&raw, Provider::Gmail)?;
    let mut options = std::fs::OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(&raw)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Clients {
    gmail: String,
    outlook: String,
    google_desktop_secret: String,
}

fn parse(raw: &[u8], provider: Provider) -> Result<ClientConfig> {
    if raw.len() as u64 > CONFIG_LIMIT {
        return Err("Provider configuration is too large".into());
    }
    let clients: Clients = serde_json::from_slice(raw)?;
    let google = &clients.gmail;
    let microsoft: Vec<_> = clients.outlook.split('-').collect();
    let valid_google = google.len() <= 256
        && google.ends_with(".apps.googleusercontent.com")
        && google
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'.'));
    let valid_microsoft = microsoft.iter().map(|part| part.len()).eq([8, 4, 4, 4, 12])
        && microsoft
            .iter()
            .all(|part| part.bytes().all(|c| c.is_ascii_hexdigit()));
    let desktop = &clients.google_desktop_secret;
    if !valid_google
        || !valid_microsoft
        || desktop.is_empty()
        || desktop.len() > 256
        || desktop.chars().any(char::is_control)
    {
        return Err("Invalid public desktop client configuration".into());
    }
    let client_id = match provider {
        Provider::Gmail => clients.gmail,
        Provider::Outlook => clients.outlook,
        Provider::Local => return Err("Local mail does not use OAuth".into()),
    };
    Ok(ClientConfig {
        client_id,
        // Desktop application metadata is public. PKCE and user consent protect account access.
        client_secret: (provider == Provider::Gmail).then_some(clients.google_desktop_secret),
    })
}

pub(super) fn client(provider: Provider) -> Result<ClientConfig> {
    // Read only when connecting. App startup and background sync do no resource polling.
    let exe = std::env::current_exe()?;
    let contents = exe
        .parent()
        .and_then(|p| p.parent())
        .ok_or("Invalid app location")?;
    let path = contents.join("Resources/OAuthClients.json");
    let mut raw = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| "This build needs provider setup in Accounts, Advanced setup")?
        .take(CONFIG_LIMIT + 1)
        .read_to_end(&mut raw)?;
    parse(&raw, provider)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn defaults_preserve_overrides() {
        use security_framework::base::Error;
        let default = || {
            Ok(ClientConfig {
                client_id: "release".into(),
                client_secret: None,
            })
        };
        let fresh = super::super::resolve_client(
            Err(Error::from_code(super::super::KEYCHAIN_NOT_FOUND)),
            default,
        )
        .unwrap();
        assert_eq!(fresh.client_id, "release");
        let custom = br#"{"client_id":"custom","client_secret":"kept"}"#.to_vec();
        let value =
            super::super::resolve_client(Ok(custom), || panic!("override must win")).unwrap();
        assert_eq!(value.client_id, "custom");
        assert_eq!(value.client_secret.as_deref(), Some("kept"));
        assert!(
            super::super::resolve_client(Err(Error::from_code(-25293)), || panic!(
                "permission errors must not switch clients"
            ))
            .is_err()
        );
        assert!(
            super::super::resolve_client(Ok(b"invalid".to_vec()), || panic!(
                "malformed overrides must remain visible"
            ))
            .is_err()
        );
    }

    #[test]
    fn release_clients_are_public_only() {
        let mut value = json!({"gmail":"123-example.apps.googleusercontent.com","outlook":"12345678-1234-1234-1234-123456789abc","google_desktop_secret":"desktop-public-metadata"});
        let raw = serde_json::to_vec(&value).unwrap();
        assert_eq!(
            parse(&raw, Provider::Gmail).unwrap().client_id,
            value["gmail"]
        );
        assert_eq!(
            parse(&raw, Provider::Outlook).unwrap().client_id,
            value["outlook"]
        );
        assert_eq!(
            parse(&raw, Provider::Gmail)
                .unwrap()
                .client_secret
                .as_deref(),
            Some("desktop-public-metadata")
        );
        assert!(
            parse(&raw, Provider::Outlook)
                .unwrap()
                .client_secret
                .is_none()
        );
        assert!(parse(&raw, Provider::Local).is_err());
        for field in [
            "access_token",
            "refresh_token",
            "client_secret",
            "authorize_url",
        ] {
            value[field] = json!("must not ship");
            assert!(parse(&serde_json::to_vec(&value).unwrap(), Provider::Gmail).is_err());
            value.as_object_mut().unwrap().remove(field);
        }
        for bad in [
            "",
            "https://example.com",
            "1234",
            "evil.apps.googleusercontent.com/path",
        ] {
            let mut changed = value.clone();
            changed["gmail"] = json!(bad);
            assert!(parse(&serde_json::to_vec(&changed).unwrap(), Provider::Gmail).is_err());
        }
        value["outlook"] = json!("bad");
        assert!(parse(&serde_json::to_vec(&value).unwrap(), Provider::Outlook).is_err());
        assert!(parse(&vec![b' '; CONFIG_LIMIT as usize + 1], Provider::Gmail).is_err());
    }
}
