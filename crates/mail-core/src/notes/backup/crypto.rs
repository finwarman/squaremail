use crate::Result;
use argon2::{Algorithm, Argon2, Params, Version};
use base64::{Engine, engine::general_purpose::STANDARD};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use zeroize::Zeroizing;

const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;
const KDF: &str = "argon2id-v19-m65536-t3-p1";
const ENVELOPE_VERSION: u32 = 1;
pub(super) type Secret = Zeroizing<Vec<u8>>;
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Header {
    pub version: u32,
    pub kdf: String,
    pub salt: String,
    pub wrapped: String,
}

pub(super) fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    rand::rng().fill_bytes(&mut bytes);
    bytes
}
pub(super) fn identifier() -> String {
    random::<16>().iter().map(|b| format!("{b:02x}")).collect()
}
fn derive(password: &str, salt: &[u8]) -> Result<Secret> {
    if !(12..=1024).contains(&password.len()) {
        return Err("Use a vault passphrase of 12 to 1,024 bytes".into());
    }
    let mut key = Zeroizing::new(vec![0; KEY_BYTES]);
    let params =
        Params::new(65536, 3, 1, Some(KEY_BYTES)).map_err(|_| "Invalid vault key parameters")?;
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|_| "Vault key derivation failed")?;
    Ok(key)
}
fn seal(key: &[u8], aad: &str, text: &[u8]) -> Result<String> {
    let nonce = random::<NONCE_BYTES>();
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(|_| "Invalid vault key")?;
    let encrypted = cipher
        .encrypt(
            &XNonce::from(nonce),
            Payload {
                msg: text,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| "Vault encryption failed")?;
    let mut packet = Vec::with_capacity(NONCE_BYTES + encrypted.len());
    packet.extend(nonce);
    packet.extend(encrypted);
    Ok(STANDARD.encode(packet))
}
fn unseal(key: &[u8], aad: &str, raw: &str, limit: usize) -> Result<Secret> {
    if raw.len() > limit {
        return Err("Encrypted note exceeds the limit".into());
    }
    let packet = STANDARD.decode(raw).map_err(|_| "Invalid encrypted note")?;
    if packet.len() < NONCE_BYTES + 16 {
        return Err("Invalid encrypted note".into());
    }
    let nonce: [u8; NONCE_BYTES] = packet[..NONCE_BYTES].try_into()?;
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(|_| "Invalid vault key")?;
    let bytes = cipher
        .decrypt(
            &XNonce::from(nonce),
            Payload {
                msg: &packet[NONCE_BYTES..],
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| "Wrong vault passphrase or damaged encrypted content")?;
    Ok(Zeroizing::new(bytes))
}
pub(super) fn create(id: &str, password: &str) -> Result<(Header, Secret)> {
    let salt = random::<16>();
    let key = Zeroizing::new(random::<KEY_BYTES>().to_vec());
    let wrapping = derive(password, &salt)?;
    let wrapped = seal(&wrapping, &format!("squaremail.vault.v1:{id}"), &key)?;
    Ok((
        Header {
            version: ENVELOPE_VERSION,
            kdf: KDF.into(),
            salt: STANDARD.encode(salt),
            wrapped,
        },
        key,
    ))
}
pub(super) fn unlock(id: &str, password: &str, header: &Header) -> Result<Secret> {
    if header.version != ENVELOPE_VERSION
        || header.kdf != KDF
        || header.salt.len() != 24
        || header.wrapped.len() != 96
    {
        return Err("Unsupported vault format".into());
    }
    let salt = STANDARD.decode(&header.salt)?;
    if salt.len() != 16 {
        return Err("Invalid vault salt".into());
    }
    let wrapping = derive(password, &salt)?;
    let key = unseal(
        &wrapping,
        &format!("squaremail.vault.v1:{id}"),
        &header.wrapped,
        96,
    )?;
    if key.len() != KEY_BYTES {
        return Err("Invalid vault key".into());
    }
    Ok(key)
}
pub(super) fn object_id(key: &[u8], id: &str) -> Result<String> {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).map_err(|_| "Invalid vault key")?;
    mac.update(b"squaremail.note.id.v1:");
    mac.update(id.as_bytes());
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
pub(super) fn encrypt(
    key: &[u8],
    vault: &str,
    object: &str,
    revision: &str,
    id: &str,
    text: &str,
) -> Result<String> {
    if id.len() > 200 || text.len() > super::super::NOTE_BYTES {
        return Err("Note exceeds the backup limit".into());
    }
    let mut packet = Zeroizing::new(Vec::with_capacity(2 + id.len() + text.len()));
    packet.extend((id.len() as u16).to_be_bytes());
    packet.extend(id.as_bytes());
    packet.extend(text.as_bytes());
    seal(
        key,
        &format!("squaremail.note.v1:{vault}:{object}:{revision}"),
        &packet,
    )
}
pub(super) fn decrypt(
    key: &[u8],
    vault: &str,
    object: &str,
    revision: &str,
    blob: &str,
) -> Result<(String, String)> {
    let packet = unseal(
        key,
        &format!("squaremail.note.v1:{vault}:{object}:{revision}"),
        blob,
        1_400_000,
    )?;
    if packet.len() < 2 {
        return Err("Invalid encrypted note".into());
    }
    let length = u16::from_be_bytes([packet[0], packet[1]]) as usize;
    if length == 0
        || length > 200
        || packet.len() < 2 + length
        || packet.len() - 2 - length > super::super::NOTE_BYTES
    {
        return Err("Invalid encrypted note bounds".into());
    }
    let id = String::from_utf8(packet[2..2 + length].to_vec())?;
    if object_id(key, &id)? != object {
        return Err("Encrypted note identity mismatch".into());
    }
    Ok((id, String::from_utf8(packet[2 + length..].to_vec())?))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn vault_envelope_and_tampering() {
        let (header, key) = create("vault-a", "generated-test-passphrase").unwrap();
        assert_eq!(
            &*unlock("vault-a", "generated-test-passphrase", &header).unwrap(),
            &*key
        );
        assert!(unlock("vault-a", "another-test-passphrase", &header).is_err());
        assert!(unlock("vault-b", "generated-test-passphrase", &header).is_err());
        let id = "Daily/2026-11-23.md";
        let object = object_id(&key, id).unwrap();
        let revision = identifier();
        let encrypted = encrypt(
            &key,
            "vault-a",
            &object,
            &revision,
            id,
            "# Private title\n- [ ] Private task",
        )
        .unwrap();
        assert!(!encrypted.contains("Private"));
        assert_eq!(
            decrypt(&key, "vault-a", &object, &revision, &encrypted).unwrap(),
            (id.into(), "# Private title\n- [ ] Private task".into())
        );
        assert!(decrypt(&key, "vault-b", &object, &revision, &encrypted).is_err());
        assert!(decrypt(&key, "vault-a", &object, &identifier(), &encrypted).is_err());
        let mut corrupt = STANDARD.decode(&encrypted).unwrap();
        corrupt[30] ^= 1;
        assert!(
            decrypt(
                &key,
                "vault-a",
                &object,
                &revision,
                &STANDARD.encode(corrupt)
            )
            .is_err()
        );
    }
}
