use super::{Config, crypto::Header};
use crate::{Result, network};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
const ENDPOINT: &str = "https://f1nb0.dev/notes-sync/v1";
#[derive(Deserialize)]
pub(super) struct RemoteObject {
    pub id: String,
    pub revision: String,
    pub blob: String,
}
#[derive(Deserialize)]
pub(super) struct Change {
    pub id: String,
    pub revision: String,
    pub sequence: i64,
}
#[derive(Deserialize)]
pub(super) struct Changes {
    pub items: Vec<Change>,
    pub more: bool,
}
#[derive(Serialize, Deserialize)]
pub(super) struct History {
    pub revision: String,
    pub created: i64,
}
pub(super) struct Remote<'a> {
    config: &'a Config,
    auth: &'a str,
    context: &'a network::Context<'a>,
}
impl<'a> Remote<'a> {
    pub fn new(config: &'a Config, auth: &'a str, context: &'a network::Context<'a>) -> Self {
        Self {
            config,
            auth,
            context,
        }
    }
    fn endpoint(&self) -> String {
        #[cfg(test)]
        if let Some(url) = &self.config.fixture_endpoint {
            return url.clone();
        }
        ENDPOINT.into()
    }
    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
    ) -> Result<reqwest::blocking::RequestBuilder> {
        self.context.check()?;
        Ok(network::client()?
            .request(method, format!("{}{path}", self.endpoint()))
            .bearer_auth(format!("{}.{}", self.config.account, self.auth)))
    }
    fn send(&self, request: reqwest::blocking::RequestBuilder) -> Result<Value> {
        Ok(self.context.send_limited(request, 1_500_000)?.value)
    }
    pub fn create(&self, invite: &str) -> Result<()> {
        self.send(self.request(reqwest::Method::POST,"/vaults")?.json(&json!({"id":self.config.account,"auth":self.auth,"invite":invite,"header":self.config.header})))?;
        Ok(())
    }
    pub fn header(&self) -> Result<Header> {
        let value = self.send(self.request(reqwest::Method::GET, "/vault")?)?;
        Ok(serde_json::from_value(value["header"].clone())?)
    }
    pub fn changes(&self, after: i64) -> Result<Changes> {
        let value: Changes = serde_json::from_value(
            self.send(self.request(reqwest::Method::GET, &format!("/changes?after={after}"))?)?,
        )?;
        if value.items.len() > 50
            || value
                .items
                .windows(2)
                .any(|w| w[1].sequence <= w[0].sequence)
            || value.items.iter().any(|v| {
                v.sequence <= after
                    || !super::valid_hex(&v.id, 64)
                    || !super::valid_hex(&v.revision, 32)
            })
        {
            return Err("Invalid Notes change list".into());
        }
        Ok(value)
    }
    pub fn get(&self, id: &str, revision: Option<&str>) -> Result<RemoteObject> {
        if !super::valid_hex(id, 64) || revision.is_some_and(|r| !super::valid_hex(r, 32)) {
            return Err("Invalid backup note identity".into());
        }
        let path = format!(
            "/objects/{id}{}",
            revision
                .map(|r| format!("?version={r}"))
                .unwrap_or_default()
        );
        let value: RemoteObject =
            serde_json::from_value(self.send(self.request(reqwest::Method::GET, &path)?)?)?;
        if value.id != id
            || !super::valid_hex(&value.revision, 32)
            || revision.is_some_and(|expected| value.revision != expected)
        {
            return Err("Invalid Notes backup response".into());
        }
        Ok(value)
    }
    pub fn put(&self, id: &str, revision: &str, base: Option<&str>, blob: &str) -> Result<()> {
        let request = self
            .request(reqwest::Method::PUT, &format!("/objects/{id}"))?
            .json(&json!({"revision":revision,"blob":blob}));
        let request = if let Some(base) = base {
            request.header("If-Match", base)
        } else {
            request.header("If-None-Match", "*")
        };
        let reply = self.send(request)?;
        if reply["revision"].as_str() != Some(revision) {
            return Err("Notes upload was not acknowledged".into());
        }
        Ok(())
    }
    pub fn history(&self, id: &str) -> Result<Vec<History>> {
        if !super::valid_hex(id, 64) {
            return Err("Invalid backup note identity".into());
        }
        let value = self.send(self.request(reqwest::Method::GET, &format!("/history/{id}"))?)?;
        let rows: Vec<History> = serde_json::from_value(value["items"].clone())?;
        if rows.len() > 50 || rows.iter().any(|r| !super::valid_hex(&r.revision, 32)) {
            return Err("Invalid backup history".into());
        }
        Ok(rows)
    }
}
