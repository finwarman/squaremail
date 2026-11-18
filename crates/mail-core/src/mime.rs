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
