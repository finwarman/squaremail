use super::*;
use crate::model::*;
use reqwest::Method;
use serde_json::json;

pub(crate) struct MailRemote<'a> {
    account: &'a Account,
    context: &'a Context<'a>,
    token: String,
    root: String,
}
impl<'a> MailRemote<'a> {
    pub(crate) fn new(account: &'a Account, token: String, context: &'a Context<'a>) -> Self {
        Self {
            account,
            context,
            token,
            root: if account.provider == Provider::Gmail {
                GMAIL_ROOT.into()
            } else {
                GRAPH_ROOT.into()
            },
        }
    }
    #[cfg(test)]
    pub(crate) fn fixture(account: &'a Account, context: &'a Context<'a>, root: String) -> Self {
        Self {
            account,
            context,
            token: "synthetic".into(),
            root,
        }
    }
    fn call(&self, method: Method, path: &str, value: Option<&Value>) -> Result<Value> {
        let mut request = network::client()?
            .request(method, format!("{}{path}", self.root))
            .bearer_auth(&self.token)
            .header("Prefer", "IdType=\"ImmutableId\"");
        if let Some(value) = value {
            request = request.json(value);
        } else {
            request = request.header("Content-Length", "0");
        }
        Ok(self.context.send(request)?.value)
    }
    pub(crate) fn headers(&self, message: &Message) -> Result<ReplyHeaders> {
        let id = encoded(&message.remote_id);
        if self.account.provider == Provider::Gmail {
            let value=self.call(Method::GET,&format!("/messages/{id}?format=metadata&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Reply-To&metadataHeaders=Message-ID&metadataHeaders=References"),None)?;
            return gmail_headers(&value);
        }
        let value=self.call(Method::GET,&format!("/messages/{id}?$select=toRecipients,ccRecipients,replyTo,internetMessageId,internetMessageHeaders"),None)?;
        Ok(graph_headers(&value))
    }
    pub(crate) fn action(&self, work: &QueuedMail, folders: &[MailFolder]) -> Result<()> {
        let id = encoded(&work.message.remote_id);
        let gmail = self.account.provider == Provider::Gmail;
        let destination = |system: Folder| -> Result<String> {
            folders
                .iter()
                .find(|f| f.system.as_deref() == Some(system.as_str()))
                .map(|f| f.id.clone())
                .or_else(|| match system {
                    Folder::Trash => Some("deleteditems".into()),
                    Folder::Archive => Some("archive".into()),
                    _ => None,
                })
                .ok_or_else(|| "Sync this account's folders before moving mail".into())
        };
        if gmail {
            let modify = match &work.action {
                MailAction::Read { unread } => {
                    if *unread {
                        json!({"addLabelIds":["UNREAD"]})
                    } else {
                        json!({"removeLabelIds":["UNREAD"]})
                    }
                }
                MailAction::Flag { flagged } => {
                    if *flagged {
                        json!({"addLabelIds":["STARRED"]})
                    } else {
                        json!({"removeLabelIds":["STARRED"]})
                    }
                }
                MailAction::Trash => {
                    self.call(
                        Method::POST,
                        &format!("/messages/{id}/trash"),
                        Some(&json!({})),
                    )?;
                    return Ok(());
                }
                MailAction::Archive => {
                    if work
                        .before
                        .folders
                        .iter()
                        .any(|f| f == Folder::Trash.as_str())
                    {
                        self.call(
                            Method::POST,
                            &format!("/messages/{id}/untrash"),
                            Some(&json!({})),
                        )?;
                    }
                    json!({"removeLabelIds":["INBOX"]})
                }
                MailAction::Move {
                    destination,
                    source,
                } => {
                    if work
                        .before
                        .folders
                        .iter()
                        .any(|f| f == Folder::Trash.as_str())
                    {
                        self.call(
                            Method::POST,
                            &format!("/messages/{id}/untrash"),
                            Some(&json!({})),
                        )?;
                    }
                    let target = destination
                        .strip_prefix("label:")
                        .ok_or("Invalid Gmail label")?;
                    let mut remove = Vec::new();
                    if target != "INBOX" {
                        remove.push("INBOX".to_string());
                    }
                    if let Some(source) = source.as_deref().and_then(|s| s.strip_prefix("label:"))
                        && source != target
                        && source != "TRASH"
                    {
                        remove.push(source.into());
                    }
                    json!({"addLabelIds":[target],"removeLabelIds":remove})
                }
            };
            self.call(
                Method::POST,
                &format!("/messages/{id}/modify"),
                Some(&modify),
            )?;
            return Ok(());
        }
        let patch = match &work.action {
            MailAction::Read { unread } => Some(json!({"isRead":!unread})),
            MailAction::Flag { flagged } => {
                Some(json!({"flag":{"flagStatus":if *flagged{"flagged"}else{"notFlagged"}}}))
            }
            _ => None,
        };
        if let Some(value) = patch {
            self.call(Method::PATCH, &format!("/messages/{id}"), Some(&value))?;
            return Ok(());
        }
        let target: String = match &work.action {
            MailAction::Trash => destination(Folder::Trash)?,
            MailAction::Archive => destination(Folder::Archive)?,
            MailAction::Move { destination, .. } => destination.clone(),
            _ => unreachable!(),
        };
        let current = self.call(
            Method::GET,
            &format!("/messages/{id}?$select=id,parentFolderId"),
            None,
        )?;
        if current["parentFolderId"].as_str() == Some(&target) {
            return Ok(());
        }
        let result = self.call(
            Method::POST,
            &format!("/messages/{id}/move"),
            Some(&json!({"destinationId":target})),
        )?;
        if result["id"].as_str() != Some(&work.message.remote_id) {
            return Err("Provider changed an immutable message ID. Check the destination and resync before retrying.".into());
        }
        Ok(())
    }
    pub(crate) fn create_draft(
        &self,
        draft: &MailDraft,
        original: Option<&Message>,
    ) -> Result<String> {
        let path = match (draft.kind, original) {
            (ComposeKind::Reply, Some(m)) => {
                format!("/messages/{}/createReply", encoded(&m.remote_id))
            }
            (ComposeKind::ReplyAll, Some(m)) => {
                format!("/messages/{}/createReplyAll", encoded(&m.remote_id))
            }
            _ => "/messages".into(),
        };
        let value = if path == "/messages" {
            graph_draft(draft)
        } else {
            json!({})
        };
        let result = self.call(Method::POST, &path, Some(&value))?;
        result["id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 2048)
            .map(String::from)
            .ok_or_else(|| "Provider omitted the created draft ID".into())
    }
    pub(crate) fn update_draft(&self, id: &str, draft: &MailDraft) -> Result<()> {
        let current = self.call(
            Method::GET,
            &format!("/messages/{}?$select=isDraft", encoded(id)),
            None,
        )?;
        if current["isDraft"] != true {
            return Err(
                "Provider draft is no longer editable. Check Sent before continuing.".into(),
            );
        }
        self.call(
            Method::PATCH,
            &format!("/messages/{}", encoded(id)),
            Some(&graph_draft(draft)),
        )?;
        Ok(())
    }
    pub(crate) fn send(&self, draft: &MailDraft, from: &str, remote: Option<&str>) -> Result<()> {
        if self.account.provider == Provider::Gmail {
            let raw = mime::wire_message(draft, from)?;
            let mut value = json!({"raw":URL_SAFE_NO_PAD.encode(raw)});
            if let Some(headers) = &draft.headers
                && !headers.thread.is_empty()
                && matches!(draft.kind, ComposeKind::Reply | ComposeKind::ReplyAll)
            {
                value["threadId"] = json!(headers.thread);
            }
            self.call(Method::POST, "/messages/send", Some(&value))?;
        } else {
            self.call(
                Method::POST,
                &format!(
                    "/messages/{}/send",
                    encoded(remote.ok_or("Provider draft is missing")?)
                ),
                None,
            )?;
        }
        Ok(())
    }
}
fn graph_draft(draft: &MailDraft) -> Value {
    let recipients = |values: &Vec<String>| {
        values
            .iter()
            .map(|a| json!({"emailAddress":{"address":a}}))
            .collect::<Vec<_>>()
    };
    json!({"subject":draft.subject,"body":{"contentType":"Text","content":draft.text},"toRecipients":recipients(&draft.to),"ccRecipients":recipients(&draft.cc),"bccRecipients":recipients(&draft.bcc)})
}
pub(super) fn gmail_headers(value: &Value) -> Result<ReplyHeaders> {
    let raw = value["payload"]["headers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|h| Some((h["name"].as_str()?, h["value"].as_str()?)))
        .filter(|(k, v)| {
            !k.contains(['\r', '\n', ':']) && !v.contains(['\r', '\n']) && v.len() < 8192
        })
        .map(|(k, v)| format!("{k}: {v}\r\n"))
        .collect::<String>()
        + "\r\n";
    mime::reply_headers(raw.as_bytes(), value["threadId"].as_str().unwrap_or(""))
}
pub(super) fn graph_headers(value: &Value) -> ReplyHeaders {
    let recipients = |key: &str| {
        value[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|r| r["emailAddress"]["address"].as_str())
            .take(100)
            .map(String::from)
            .collect()
    };
    ReplyHeaders {
        to: recipients("toRecipients"),
        cc: recipients("ccRecipients"),
        reply_to: recipients("replyTo"),
        message_id: value["internetMessageId"]
            .as_str()
            .unwrap_or("")
            .trim_matches(['<', '>'])
            .into(),
        references: value["internetMessageHeaders"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|h| {
                h["name"]
                    .as_str()
                    .is_some_and(|n| n.eq_ignore_ascii_case("References"))
            })
            .and_then(|h| h["value"].as_str())
            .unwrap_or("")
            .into(),
        thread: String::new(),
    }
}
fn encoded(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}
