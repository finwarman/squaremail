use crate::network::{self, Context};
use crate::{Result, mime, model::*, oauth, store::Store};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD},
};
use serde_json::Value;

const GMAIL_ROOT: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
const GRAPH_ROOT: &str = "https://graph.microsoft.com/v1.0/me";

mod media;
mod sync;
pub(crate) use media::{attachment_bytes, media_content};
pub(crate) use sync::edit_summary;
pub(crate) use sync::sync_next;

pub(crate) fn body(
    account: &Account,
    remote_id: &str,
    context: &Context<'_>,
) -> Result<(String, String)> {
    let client = network::client()?;
    let token = oauth::access_token(account, context)?;
    let id: String = url::form_urlencoded::byte_serialize(remote_id.as_bytes()).collect();
    match account.provider {
        Provider::Gmail => {
            let value = context
                .send(
                    client
                        .get(format!("{GMAIL_ROOT}/messages/{id}?format=full"))
                        .bearer_auth(&token),
                )?
                .value;
            let mut body = Vec::new();
            let mut decoded_bytes = 0;
            body.extend_from_slice(b"MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=squaremail-body\r\n\r\n");
            for part in body_parts(&value["payload"])? {
                let response;
                let content = if let Some(data) = part["body"]["data"].as_str() {
                    data
                } else if let Some(attachment) = part["body"]["attachmentId"].as_str() {
                    if part["body"]["size"].as_u64().unwrap_or(0) > MAX_BODY_BYTES as u64 {
                        return Err("Message text exceeds the 4 MiB reader limit".into());
                    }
                    let attachment = url::form_urlencoded::byte_serialize(attachment.as_bytes())
                        .collect::<String>();
                    response = context
                        .send(
                            client
                                .get(format!(
                                    "{GMAIL_ROOT}/messages/{id}/attachments/{attachment}"
                                ))
                                .bearer_auth(&token),
                        )?
                        .value;
                    response["data"]
                        .as_str()
                        .ok_or("Provider omitted the text body")?
                } else {
                    continue;
                };
                let bytes = URL_SAFE_NO_PAD
                    .decode(content)
                    .or_else(|_| URL_SAFE.decode(content))?;
                decoded_bytes += bytes.len();
                if decoded_bytes > MAX_BODY_BYTES {
                    return Err("Message text exceeds the 4 MiB reader limit".into());
                }
                append_body(&mut body, part, &bytes);
            }
            body.extend_from_slice(b"--squaremail-body--\r\n");
            mime::alternatives(&body)
        }

        Provider::Outlook => {
            let url = format!("{GRAPH_ROOT}/messages/{id}?$select=body");
            let html = context
                .send(
                    client
                        .get(&url)
                        .bearer_auth(&token)
                        .header("Prefer", "IdType=\"ImmutableId\""),
                )?
                .value;
            let text = context
                .send(client.get(&url).bearer_auth(&token).header(
                    "Prefer",
                    "IdType=\"ImmutableId\", outlook.body-content-type=\"text\"",
                ))?
                .value;
            Ok((
                string(&text["body"], "content"),
                string(&html["body"], "content"),
            ))
        }
        Provider::Local => Err("Local message body is unavailable".into()),
    }
}

const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

fn body_parts(payload: &Value) -> Result<Vec<&Value>> {
    let mut pending = vec![(payload, 0)];
    let mut parts = Vec::new();
    let mut seen = 0;
    let mut plain = false;
    let mut html = false;
    while let Some((part, depth)) = pending.pop() {
        seen += 1;
        if seen > 128 || depth > 16 {
            return Err("Message MIME structure exceeds the reader limit".into());
        }
        if part["filename"].as_str().is_some_and(|s| !s.is_empty()) {
            continue;
        }
        match part["mimeType"].as_str().unwrap_or("") {
            "text/plain" if !plain => {
                plain = true;
                parts.push(part);
            }
            "text/html" if !html => {
                html = true;
                parts.push(part);
            }
            mime if mime.starts_with("multipart/") => {
                let children = part["parts"].as_array();
                if pending.len() + children.map_or(0, Vec::len) > 128 {
                    return Err("Message MIME structure exceeds the reader limit".into());
                }
                for child in children.into_iter().flatten().rev() {
                    pending.push((child, depth + 1));
                }
            }
            _ => {}
        }
    }
    Ok(parts)
}
fn append_body(body: &mut Vec<u8>, part: &Value, bytes: &[u8]) {
    let content_type = part["headers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|h| {
            h["name"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case("content-type"))
        })
        .and_then(|h| h["value"].as_str())
        .filter(|s| s.len() < 1024 && !s.contains(['\r', '\n']))
        .unwrap_or_else(|| part["mimeType"].as_str().unwrap_or("text/plain"));
    body.extend_from_slice(format!("--squaremail-body\r\nContent-Type: {content_type}\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",STANDARD.encode(bytes)).as_bytes());
}

fn gmail_message(value: &Value, account: &Account) -> Result<Message> {
    let headers = value["payload"]["headers"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let header = |name: &str| {
        headers
            .iter()
            .find(|h| {
                h["name"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(name))
            })
            .and_then(|h| h["value"].as_str())
            .unwrap_or("")
            .to_string()
    };
    let remote = value["id"]
        .as_str()
        .ok_or("Provider returned a message without an ID")?;
    let labels = value["labelIds"].as_array().cloned().unwrap_or_default();
    let from = header("From");
    let (sender, address) = split_address(&from);
    Ok(Message {
        id: mime::message_id(&account.id, remote),
        account_id: account.id.clone(),
        remote_id: remote.into(),
        sender,
        sender_address: address,
        recipient: header("To"),
        subject: header("Subject"),
        preview: string(value, "snippet"),
        timestamp: value["internalDate"]
            .as_str()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0)
            / 1000,
        unread: labels.iter().any(|v| v == "UNREAD"),
        starred: labels.iter().any(|v| v == "STARRED"),
        has_attachments: false,
        text: None,
        html: None,
    })
}

fn outlook_message(value: &Value, account: &Account) -> Result<Message> {
    let remote = value["id"]
        .as_str()
        .ok_or("Provider returned a message without an ID")?;
    let from = &value["from"]["emailAddress"];
    Ok(Message {
        id: mime::message_id(&account.id, remote),
        account_id: account.id.clone(),
        remote_id: remote.into(),
        sender: string(from, "name"),
        sender_address: string(from, "address"),
        recipient: value["toRecipients"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|r| r["emailAddress"]["address"].as_str())
            .collect::<Vec<_>>()
            .join(", "),
        subject: string(value, "subject"),
        preview: string(value, "bodyPreview"),
        timestamp: value["receivedDateTime"]
            .as_str()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|d| d.timestamp())
            .unwrap_or(0),
        unread: !value["isRead"].as_bool().unwrap_or(true),
        starred: value["flag"]["flagStatus"] == "flagged",
        has_attachments: value["hasAttachments"].as_bool().unwrap_or(false),
        text: None,
        html: None,
    })
}

fn split_address(value: &str) -> (String, String) {
    if let Some((name, rest)) = value.rsplit_once('<') {
        return (
            name.trim().trim_matches('"').into(),
            rest.trim_end_matches('>').trim().into(),
        );
    }
    (value.into(), value.into())
}

fn string(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or("").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn providers_preserve_metadata() {
        let account = Account {
            id: "a".into(),
            email: "a@example.test".into(),
            provider: Provider::Gmail,
        };
        let gmail = gmail_message(&json!({"id":"123", "internalDate":"1700000000000", "labelIds":["UNREAD", "STARRED"],
            "payload":{"headers":[{"name":"from","value":"Ada <ada@example.test>"},{"name":"Subject","value":"Notes"}]}}), &account).unwrap();
        assert_eq!(gmail.timestamp, 1700000000);
        assert_eq!(gmail.sender_address, "ada@example.test");
        assert!(gmail.unread && gmail.starred);
        let graph = outlook_message(&json!({"id":"123","subject":"Notes","isRead":true,"hasAttachments":true,
            "receivedDateTime":"2023-11-14T22:13:20Z","from":{"emailAddress":{"name":"Ada","address":"ada@example.test"}}}), &account).unwrap();
        assert_eq!(graph.timestamp, gmail.timestamp);
        assert!(!graph.unread);
        assert!(graph.has_attachments);
    }
    #[test]
    fn gmail_body_skips_file_payloads() {
        let payload = json!({"mimeType":"multipart/mixed","parts":[
            {"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"Y2Fm6Q"},"headers":[{"name":"Content-Type","value":"text/plain; charset=iso-8859-1"}]},{"mimeType":"text/html","body":{"data":"PGI-SGk8L2I-"}}]},
            {"mimeType":"application/pdf","filename":"invoice.pdf","body":{"attachmentId":"do-not-fetch"}},
            {"mimeType":"text/plain","filename":"notes.txt","body":{"attachmentId":"do-not-fetch-either"}}]});
        let parts = body_parts(&payload).unwrap();
        assert_eq!(parts.len(), 2);
        let mut body=b"MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=squaremail-body\r\n\r\n".to_vec();
        for part in parts {
            let bytes = URL_SAFE_NO_PAD
                .decode(part["body"]["data"].as_str().unwrap())
                .unwrap();
            append_body(&mut body, part, &bytes);
        }
        body.extend_from_slice(b"--squaremail-body--\r\n");
        let message = mime::parse(&body, "a", "one").unwrap();
        assert!(message.text.unwrap().contains("café"));
        assert!(message.html.unwrap().contains("<b>Hi</b>"));
    }
}
