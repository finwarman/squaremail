use base64::{Engine, engine::general_purpose::STANDARD};
use security_framework::base::{Error, Result};
use serde::Serialize;
use serde_json::json;
use std::{
    io::Write,
    process::{Command, Stdio},
    sync::Mutex,
};

static HELPER: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);
const NOT_AVAILABLE: i32 = -25291;
const RULE: &str = "=identifier \"com.finwarman.squaremail.credentials\" and certificate leaf = H\"E9EDA8C68084E31D00019CB550FCB9294D486364\"";

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Operation {
    Get,
    Set,
    Delete,
}

fn request(
    operation: Operation,
    service: &str,
    account: &str,
    data: Option<&[u8]>,
) -> Result<Vec<u8>> {
    let error = || Error::from_code(NOT_AVAILABLE);
    let mut helper = HELPER.lock().map_err(|_| error())?;
    if helper.is_none() {
        let exe = std::env::current_exe().map_err(|_| error())?;
        let root = exe.parent().and_then(|p| p.parent()).ok_or_else(error)?;
        let path = root.join("Helpers/SquareMailCredentials");
        let check = Command::new("/usr/bin/codesign")
            .args(["--verify", "--strict", "--test-requirement", RULE])
            .arg(&path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|_| error())?;
        if !check.success() {
            return Err(error());
        }
        *helper = Some(path);
    }
    let path = helper.as_ref().ok_or_else(error)?;
    let input = serde_json::to_vec(&json!({"operation":operation,"service":service,"account":account,"data":data.map(|d| STANDARD.encode(d))})).map_err(|_| error())?;
    if input.len() > 131072 {
        return Err(error());
    }
    let mut child = Command::new(path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| error())?;
    child
        .stdin
        .take()
        .ok_or_else(error)?
        .write_all(&input)
        .map_err(|_| error())?;
    let output = child.wait_with_output().map_err(|_| error())?;
    if !output.status.success() || output.stdout.len() > 131072 {
        return Err(error());
    }
    let reply: serde_json::Value = serde_json::from_slice(&output.stdout).map_err(|_| error())?;
    let status = reply["status"].as_i64().ok_or_else(error)? as i32;
    if status != 0 {
        return Err(Error::from_code(status));
    }
    match reply["data"].as_str() {
        Some(value) => STANDARD.decode(value).map_err(|_| error()),
        None => Ok(Vec::new()),
    }
}
pub(super) fn get_generic_password(service: &str, account: &str) -> Result<Vec<u8>> {
    request(Operation::Get, service, account, None)
}
pub(super) fn set_generic_password(service: &str, account: &str, value: &[u8]) -> Result<()> {
    request(Operation::Set, service, account, Some(value)).map(|_| ())
}
pub(super) fn delete_generic_password(service: &str, account: &str) -> Result<()> {
    request(Operation::Delete, service, account, None).map(|_| ())
}
