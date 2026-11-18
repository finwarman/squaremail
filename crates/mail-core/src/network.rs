use crate::Result;
use reqwest::blocking::{Client, RequestBuilder};
use serde_json::Value;
use std::{
    io::Read,
    sync::{
        OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

const MAX_RESPONSE: u64 = 20 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(12);
static CLIENT: OnceLock<Client> = OnceLock::new();

#[derive(Default)]
pub struct CancelToken(AtomicBool);
impl CancelToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

pub(crate) struct Context<'a> {
    token: Option<&'a CancelToken>,
    deadline: Instant,
}
impl<'a> Context<'a> {
    pub(crate) fn new(token: Option<&'a CancelToken>, seconds: u64) -> Self {
        Self {
            token,
            deadline: Instant::now() + Duration::from_secs(seconds),
        }
    }
    pub(crate) fn check(&self) -> Result<()> {
        if self.token.is_some_and(|t| t.0.load(Ordering::Relaxed)) {
            return Err("Request cancelled".into());
        }
        if Instant::now() >= self.deadline {
            return Err("Request time budget expired".into());
        }
        Ok(())
    }
    pub(crate) fn send(&self, request: RequestBuilder) -> Result<Reply> {
        self.check()?;
        let response = request
            .timeout(REQUEST_TIMEOUT.min(self.deadline.saturating_duration_since(Instant::now())))
            .send()
            .map_err(|error| -> Box<dyn std::error::Error + Send + Sync> {
                if error.is_timeout() {
                    "Provider request timed out. Cached data remains available.".into()
                } else {
                    "Provider connection failed. Cached data remains available.".into()
                }
            })?;
        self.check()?;
        let status = response.status().as_u16();
        let retry = response
            .headers()
            .get("Retry-After")
            .and_then(|v| v.to_str().ok())
            .map(|s| {
                s.parse::<i64>().unwrap_or_else(|_| {
                    chrono::DateTime::parse_from_rfc2822(s)
                        .map(|d| {
                            d.timestamp()
                                .saturating_sub(chrono::Utc::now().timestamp())
                                .max(0)
                        })
                        .unwrap_or(0)
                })
            })
            .unwrap_or(0);
        let etag = response
            .headers()
            .get("ETag")
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        if status == 304 {
            return Ok(Reply {
                value: Value::Null,
                etag,
            });
        }
        if !(200..300).contains(&status) {
            return Err(Box::new(HttpError { status, retry }));
        }
        let mut raw = Vec::new();
        response.take(MAX_RESPONSE + 1).read_to_end(&mut raw)?;
        self.check()?;
        if raw.len() as u64 > MAX_RESPONSE {
            return Err("Provider response exceeded the size limit".into());
        }
        Ok(Reply {
            value: serde_json::from_slice(&raw)?,
            etag,
        })
    }
}
#[derive(Debug)]
pub(crate) struct Reply {
    pub(crate) value: Value,
    pub(crate) etag: Option<String>,
}
#[derive(Debug)]
pub(crate) struct HttpError {
    pub(crate) status: u16,
    pub(crate) retry: i64,
}
impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.status {
            401 | 403 => write!(
                f,
                "Sign-in or additional consent is required (HTTP {})",
                self.status
            ),
            429 => write!(f, "Provider rate limit. Sync will retry later"),
            _ => write!(
                f,
                "Provider returned HTTP {}. Cached data remains available",
                self.status
            ),
        }
    }
}
impl std::error::Error for HttpError {}
pub(crate) fn client() -> Result<Client> {
    if let Some(client) = CLIENT.get() {
        return Ok(client.clone());
    }
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(REQUEST_TIMEOUT)
        .pool_max_idle_per_host(2)
        .pool_idle_timeout(Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("SquareMail/0.2")
        .build()?;
    Ok(CLIENT.get_or_init(|| client).clone())
}
pub(crate) fn is_status(
    error: &(dyn std::error::Error + Send + Sync + 'static),
    status: u16,
) -> bool {
    error
        .downcast_ref::<HttpError>()
        .is_some_and(|e| e.status == status)
}
