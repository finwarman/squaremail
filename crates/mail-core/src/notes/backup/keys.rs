use crate::Result;
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;
const SERVICE: &str = "com.finwarman.squaremail.notes-vault.v1";
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Credentials {
    pub auth: String,
    pub key: Option<Vec<u8>>,
}
impl Drop for Credentials {
    fn drop(&mut self) {
        self.auth.zeroize();
        if let Some(key) = &mut self.key {
            key.zeroize();
        }
    }
}
#[cfg(not(test))]
pub(super) fn load(id: &str) -> Result<Option<Credentials>> {
    match security_framework::passwords::get_generic_password(SERVICE, id) {
        Ok(bytes) => {
            let value = zeroize::Zeroizing::new(bytes);
            Ok(Some(serde_json::from_slice(&value)?))
        }
        Err(error) if error.code() == -25300 => Ok(None),
        Err(_) => Err("Unlock Keychain to use Notes backup".into()),
    }
}
#[cfg(not(test))]
pub(super) fn save(id: &str, value: &Credentials) -> Result<()> {
    let data = zeroize::Zeroizing::new(serde_json::to_vec(value)?);
    security_framework::passwords::set_generic_password(SERVICE, id, &data)
        .map_err(|_| "Could not save the Notes backup key in Keychain")?;
    Ok(())
}
#[cfg(not(test))]
pub(super) fn remove(id: &str) -> Result<()> {
    match security_framework::passwords::delete_generic_password(SERVICE, id) {
        Ok(()) => Ok(()),
        Err(error) if error.code() == -25300 => Ok(()),
        Err(_) => Err("Could not remove the Notes backup key".into()),
    }
}
#[cfg(test)]
pub(super) fn load(id: &str) -> Result<Option<Credentials>> {
    let _ = SERVICE;
    Ok(fixture::memory().lock().unwrap().get(id).cloned())
}
#[cfg(test)]
pub(super) fn save(id: &str, value: &Credentials) -> Result<()> {
    fixture::memory()
        .lock()
        .unwrap()
        .insert(id.into(), value.clone());
    Ok(())
}
#[cfg(test)]
pub(super) fn remove(id: &str) -> Result<()> {
    fixture::memory().lock().unwrap().remove(id);
    Ok(())
}

#[cfg(test)]
mod fixture {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    pub(super) fn memory() -> &'static Mutex<HashMap<String, Credentials>> {
        static STORE: OnceLock<Mutex<HashMap<String, Credentials>>> = OnceLock::new();
        STORE.get_or_init(|| Mutex::new(HashMap::new()))
    }
}
