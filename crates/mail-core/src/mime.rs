use crate::{Result, model::Message};
use mail_parser::MessageParser;
use sha2::{Digest, Sha256};

pub(crate) fn clean_html(html: &str) -> String {
    let mut builder = ammonia::Builder::default();
    // Mail is a passive document. No images, CSS, forms or active content.
    builder.rm_tags(&[
        "img", "style", "form", "input", "button", "video", "audio", "source",
    ]);
    builder.url_schemes(["https", "http", "mailto"].into_iter().collect());
    builder.clean(html).to_string()
}

pub(crate) fn alternatives(raw: &[u8]) -> Result<(String, String)> {
    let parsed = MessageParser::default()
        .parse(raw)
        .ok_or("Invalid MIME body")?;
    Ok((
        parsed.body_text(0).unwrap_or_default().into_owned(),
        parsed.body_html(0).unwrap_or_default().into_owned(),
    ))
}

pub(crate) fn parse(raw: &[u8], account: &str, remote: &str) -> Result<Message> {
    let parsed = MessageParser::default()
        .parse(raw)
        .ok_or("The file is not a valid MIME email")?;
    let sender = parsed.from().and_then(|a| a.first());
    let text = parsed
        .body_text(0)
        .map(|v| v.into_owned())
        .unwrap_or_default();
    let html = parsed
        .body_html(0)
        .map(|v| clean_html(&v))
        .unwrap_or_default();
    Ok(Message {
        pinned: false,
        reply: Some(reply_headers(raw, "")?),
        id: message_id(account, remote),
        account_id: account.into(),
        remote_id: remote.into(),
        sender: sender
            .and_then(|s| s.name())
            .unwrap_or("Unknown sender")
            .into(),
        sender_address: sender.and_then(|s| s.address()).unwrap_or("").into(),
        recipient: parsed
            .to()
            .and_then(|a| a.first())
            .and_then(|a| a.address())
            .unwrap_or("")
            .into(),
        subject: parsed.subject().unwrap_or("(No subject)").into(),
        preview: text
            .split_whitespace()
            .take(35)
            .collect::<Vec<_>>()
            .join(" "),
        timestamp: parsed.date().map(|d| d.to_timestamp()).unwrap_or(0),
        unread: true,
        starred: false,
        has_attachments: parsed.attachment_count() > 0,
        text: Some(text),
        html: Some(html),
    })
}

pub(crate) fn message_id(account: &str, remote: &str) -> String {
    let mut hash = Sha256::new();
    hash.update(account.as_bytes());
    hash.update([0]);
    hash.update(remote.as_bytes());
    format!("{:x}", hash.finalize())
}

pub(crate) fn addresses(value: &str) -> Vec<String> {
    let raw = format!("To: {value}\r\n\r\n");
    MessageParser::default()
        .parse(raw.as_bytes())
        .and_then(|m| {
            m.to().map(|a| {
                a.iter()
                    .filter_map(|a| a.address().map(String::from))
                    .take(100)
                    .collect()
            })
        })
        .unwrap_or_default()
}
pub(crate) fn reply_headers(raw: &[u8], thread: &str) -> Result<crate::model::ReplyHeaders> {
    let parsed = MessageParser::default()
        .parse(raw)
        .ok_or("Invalid reply headers")?;
    let list = |address: Option<&mail_parser::Address<'_>>| {
        address
            .map(|a| {
                a.iter()
                    .filter_map(|a| a.address().map(String::from))
                    .take(100)
                    .collect()
            })
            .unwrap_or_default()
    };
    Ok(crate::model::ReplyHeaders {
        to: list(parsed.to()),
        cc: list(parsed.cc()),
        reply_to: list(parsed.reply_to()),
        message_id: parsed.message_id().unwrap_or("").into(),
        references: parsed
            .references()
            .as_text_list()
            .map(|v| {
                v.iter()
                    .take(30)
                    .map(|s| format!("<{s}>"))
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default(),
        thread: thread.into(),
    })
}

pub(crate) fn wire_message(draft: &crate::model::MailDraft, from: &str) -> Result<String> {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let mut words = Vec::new();
    let mut word = String::new();
    for c in draft.subject.chars() {
        if word.len() + c.len_utf8() > 30 {
            words.push(format!("=?UTF-8?B?{}?=", STANDARD.encode(word.as_bytes())));
            word.clear();
        }
        word.push(c);
    }
    if !word.is_empty() {
        words.push(format!("=?UTF-8?B?{}?=", STANDARD.encode(word.as_bytes())));
    }
    let encoded = words.join("\r\n ");
    let mut raw = format!(
        "From: {from}\r\nTo: {}\r\nCc: {}\r\nBcc: {}\r\nSubject: {encoded}\r\nDate: {}\r\nMessage-ID: <squaremail.{}@squaremail.local>\r\n",
        draft.to.join(",\r\n "),
        draft.cc.join(",\r\n "),
        draft.bcc.join(",\r\n "),
        chrono::Utc::now().to_rfc2822(),
        draft.id
    );
    if matches!(
        draft.kind,
        crate::model::ComposeKind::Reply | crate::model::ComposeKind::ReplyAll
    ) && let Some(headers) = &draft.headers
    {
        if headers.message_id.is_empty()
            || headers.message_id.len() > 500
            || headers
                .message_id
                .chars()
                .any(|c| c.is_control() || c.is_whitespace() || "<>".contains(c))
        {
            return Err("Invalid original Message-ID".into());
        }
        let mut references = headers
            .references
            .split_whitespace()
            .filter(|token| {
                token.starts_with('<')
                    && token.ends_with('>')
                    && token.len() <= 502
                    && token.chars().all(|c| !c.is_control())
            })
            .take(30)
            .map(String::from)
            .collect::<Vec<_>>();
        references.push(format!("<{}>", headers.message_id));
        raw += &format!(
            "In-Reply-To: <{}>\r\nReferences: {}\r\n",
            headers.message_id,
            references.join("\r\n ")
        );
    }
    raw += "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n";
    for chunk in STANDARD.encode(draft.text.as_bytes()).as_bytes().chunks(76) {
        raw += std::str::from_utf8(chunk)?;
        raw += "\r\n";
    }
    Ok(raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alternatives_stay_separate() {
        let raw = b"From: Ada <ada@example.test>\r\nSubject: =?UTF-8?Q?caf=C3=A9?=\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=alt\r\n\r\n--alt\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nPlain version\r\n--alt\r\nContent-Type: text/html\r\n\r\n<b>HTML version</b>\r\n--alt--";
        let message = parse(raw, "local", "1").unwrap();
        assert_eq!(message.subject, "café");
        assert!(message.text.unwrap().contains("Plain version"));
        assert!(message.html.unwrap().contains("<b>HTML version</b>"));
    }

    #[test]
    fn html_is_passive() {
        let input = "<script>alert(1)</script><img src='https://tracker.test/x'><style>body{background:url(https://tracker.test)}</style><form action='https://evil.test'><input></form><a href='javascript:alert(1)' onclick='fetch(1)'>bad</a><b>keep</b><iframe src='https://evil.test'></iframe>";
        let safe = clean_html(input);
        for forbidden in [
            "<script",
            "<img",
            "<style",
            "<form",
            "<input",
            "onclick",
            "javascript:",
            "<iframe",
        ] {
            assert!(!safe.contains(forbidden), "{safe}");
        }
        assert!(safe.contains("<b>keep</b>"));
    }
}
