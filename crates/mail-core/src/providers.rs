use crate::{Result, mime, model::*, oauth, store::Store};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use reqwest::blocking::Client;
use serde_json::Value;

const GMAIL_ROOT: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
const GRAPH_ROOT: &str = "https://graph.microsoft.com/v1.0/me";
const SYNC_LIMIT: usize = 200;

pub(crate) fn sync(store: &Store, account: &Account, folder: Folder) -> Result<usize> {
    if account.provider == Provider::Local {
        return Ok(0);
    }
    let client = oauth::http()?;
    let token = oauth::access_token(account)?;
    let messages = match account.provider {
        Provider::Gmail => gmail_headers(&client, &token, account, folder)?,
        Provider::Outlook => outlook_headers(&client, &token, account, folder)?,
        Provider::Local => unreachable!(),
    };
    for message in &messages {
        store.save(message, folder)?;
    }
    Ok(messages.len())
}

pub(crate) fn body(account: &Account, remote_id: &str) -> Result<(String, String)> {
    let client = oauth::http()?;
    let token = oauth::access_token(account)?;
    let id: String = url::form_urlencoded::byte_serialize(remote_id.as_bytes()).collect();
    match account.provider {
        Provider::Gmail => {
            let value = get(
                &client,
                &token,
                &format!("{GMAIL_ROOT}/messages/{id}?format=raw"),
            )?;
            let raw = URL_SAFE_NO_PAD.decode(
                value["raw"]
                    .as_str()
                    .ok_or("Provider returned no MIME body")?,
            )?;
            let message = mime::parse(&raw, &account.id, remote_id)?;
            Ok((
                message.text.unwrap_or_default(),
                message.html.unwrap_or_default(),
            ))
        }
        Provider::Outlook => {
            let url = format!("{GRAPH_ROOT}/messages/{id}?$select=body");
            let html = get(&client, &token, &url)?;
            let text = oauth::read_json(
                client
                    .get(&url)
                    .bearer_auth(&token)
                    .header("Prefer", "outlook.body-content-type=\"text\"")
                    .send()?,
            )?;
            Ok((
                string(&text["body"], "content"),
                string(&html["body"], "content"),
            ))
        }
        Provider::Local => Err("Local message body is unavailable".into()),
    }
}

fn get(client: &Client, token: &str, url: &str) -> Result<Value> {
    oauth::read_json(client.get(url).bearer_auth(token).send()?)
}

fn gmail_headers(
    client: &Client,
    token: &str,
    account: &Account,
    folder: Folder,
) -> Result<Vec<Message>> {
    let label = match folder {
        Folder::Sent => "SENT",
        Folder::Drafts => "DRAFT",
        Folder::Trash => "TRASH",
        Folder::Starred => "STARRED",
        Folder::Unread => "UNREAD",
        _ => "INBOX",
    };
    let mut request = client
        .get(format!("{GMAIL_ROOT}/messages"))
        .bearer_auth(token)
        .query(&[("maxResults", SYNC_LIMIT.to_string())]);
    request = match folder {
        Folder::All => request,
        Folder::Archive => {
            request.query(&[("q", "-in:inbox -in:sent -in:drafts -in:trash -in:spam")])
        }
        _ => request.query(&[("labelIds", label)]),
    };
    let list = oauth::read_json(request.send()?)?;
    let ids: Vec<_> = list["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|value| value["id"].as_str())
        .collect();
    // Bounded workers hide API latency without growing one thread per message.
    std::thread::scope(|scope| {
        let workers: Vec<_> = ids.chunks(25).map(|chunk| scope.spawn(move || -> Result<Vec<Message>> {
            chunk.iter().map(|id| {
                let value = get(client, token, &format!("{GMAIL_ROOT}/messages/{id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=To"))?;
                gmail_message(&value, account)
            }).collect()
        })).collect();
        let mut messages = Vec::with_capacity(ids.len());
        for worker in workers {
            messages.extend(worker.join().map_err(|_| "Header worker failed")??);
        }
        Ok(messages)
    })
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

fn outlook_headers(
    client: &Client,
    token: &str,
    account: &Account,
    folder: Folder,
) -> Result<Vec<Message>> {
    let folder_id = match folder {
        Folder::Sent => "sentitems",
        Folder::Drafts => "drafts",
        Folder::Archive => "archive",
        Folder::Trash => "deleteditems",
        _ => "inbox",
    };
    let base = if matches!(folder, Folder::All | Folder::Starred | Folder::Unread) {
        format!("{GRAPH_ROOT}/messages")
    } else {
        format!("{GRAPH_ROOT}/mailFolders/{folder_id}/messages")
    };
    let mut request = client.get(base).bearer_auth(token).header("Prefer", "IdType=\"ImmutableId\"")
        .query(&[("$top", SYNC_LIMIT.to_string()), ("$orderby", "receivedDateTime desc".into()),
            ("$select", "id,subject,from,toRecipients,receivedDateTime,isRead,flag,hasAttachments,bodyPreview".into())]);
    if folder == Folder::Unread {
        request = request.query(&[(
            "$filter",
            "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false",
        )]);
    }
    if folder == Folder::Starred {
        request = request.query(&[(
            "$filter",
            "receivedDateTime ge 1900-01-01T00:00:00Z and flag/flagStatus eq 'flagged'",
        )]);
    }
    let value = oauth::read_json(request.send()?)?;
    value["value"]
        .as_array()
        .ok_or("Provider returned no message list")?
        .iter()
        .map(|v| outlook_message(v, account))
        .collect()
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
}
