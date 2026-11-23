use super::*;
use crate::header_text;
use serde::Serialize;
use std::collections::HashMap;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

const CANDIDATE_LIMIT: i64 = 200;
const OUTBOX_CONTACT_LIMIT: i64 = 20;
const CONTACT_LIMIT: usize = 10;
const QUERY_BYTES: usize = 128;
const SENT_WEIGHT: i64 = 10;
const OUTBOX_WEIGHT: i64 = 20;

#[derive(Clone, Serialize)]
pub(crate) struct Contact {
    name: String,
    address: String,
}
struct Ranked {
    contact: Contact,
    score: i64,
    recent: i64,
}

impl Store {
    pub(crate) fn contacts(&self, account: &str, query: &str) -> Result<Vec<Contact>> {
        if query.len() > QUERY_BYTES || query.trim().chars().count() < 2 {
            return Ok(Vec::new());
        }
        let own = self
            .accounts()?
            .into_iter()
            .find(|a| a.id == account)
            .ok_or("Choose a sending account")?
            .email
            .to_lowercase();
        let terms = search::literal(query)?;
        if terms.is_empty() {
            return Ok(Vec::new());
        }
        let scoped = format!("{{sender sender_address}} : ({terms})");
        let mut results = HashMap::new();
        let mut stmt=self.connection.prepare("SELECT m.sender,m.sender_address,m.timestamp FROM messages m JOIN message_search ON message_search.rowid=m.rowid WHERE message_search MATCH ?1 AND m.account_id=?2 AND lower(m.sender_address)<>?4 ORDER BY m.timestamp DESC LIMIT ?3")?;
        for row in stmt.query_map(params![scoped, account, CANDIDATE_LIMIT, own], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })? {
            let (name, address, time) = row?;
            add(
                &mut results,
                &own,
                query,
                &header_text::decode(&name),
                &address,
                time,
                1,
            );
        }
        let mut stmt=self.connection.prepare("WITH recent AS (SELECT m.id,m.recipient,m.timestamp FROM messages m WHERE m.account_id=?1 AND EXISTS(SELECT 1 FROM folders f WHERE f.message_id=m.id AND f.folder='sent') ORDER BY m.timestamp DESC LIMIT ?2) SELECT r.recipient,r.timestamp,h.data FROM recent r LEFT JOIN mail_headers h ON h.message_id=r.id")?;
        for row in stmt.query_map(params![account, CANDIDATE_LIMIT], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })? {
            let (recipient, time, headers) = row?;
            addresses(&mut results, &own, query, &recipient, time, SENT_WEIGHT);
            if let Some(headers) = headers
                && let Ok(headers) = serde_json::from_str::<ReplyHeaders>(&headers)
            {
                for address in headers.to.iter().chain(&headers.cc) {
                    addresses(&mut results, &own, query, address, time, SENT_WEIGHT);
                }
            }
        }
        // Extract recipient arrays only. No message body crosses this API.
        let mut stmt=self.connection.prepare("SELECT coalesce(json_extract(data,'$.to'),'[]'),coalesce(json_extract(data,'$.cc'),'[]'),coalesce(json_extract(data,'$.bcc'),'[]'),created FROM mail_outbox WHERE account=?1 ORDER BY created DESC LIMIT ?2")?;
        for row in stmt.query_map(params![account, OUTBOX_CONTACT_LIMIT], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })? {
            let (to, cc, bcc, time) = row?;
            for list in [to, cc, bcc] {
                if let Ok(values) = serde_json::from_str::<Vec<String>>(&list) {
                    for address in values {
                        addresses(&mut results, &own, query, &address, time, OUTBOX_WEIGHT);
                    }
                }
            }
        }
        let mut values: Vec<_> = results.into_values().collect();
        values.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then(b.recent.cmp(&a.recent))
                .then(a.contact.address.cmp(&b.contact.address))
        });
        Ok(values
            .into_iter()
            .take(CONTACT_LIMIT)
            .map(|r| r.contact)
            .collect())
    }
}
fn addresses(
    output: &mut HashMap<String, Ranked>,
    own: &str,
    query: &str,
    raw: &str,
    recent: i64,
    weight: i64,
) {
    let raw = raw.chars().take(32 * 1024).collect::<String>();
    let source = format!("To: {raw}\r\n\r\n");
    let Some(message) = mail_parser::MessageParser::default().parse_headers(source.as_bytes())
    else {
        return;
    };
    let Some(list) = message.to() else { return };
    for address in list.iter().take(100) {
        if let Some(email) = address.address() {
            add(
                output,
                own,
                query,
                address.name().unwrap_or(""),
                email,
                recent,
                weight,
            );
        }
    }
}
fn add(
    output: &mut HashMap<String, Ranked>,
    own: &str,
    query: &str,
    name: &str,
    address: &str,
    recent: i64,
    weight: i64,
) {
    let address = address.trim().to_lowercase();
    let query = folded(query.trim());
    let parts: Vec<_> = address.split('@').collect();
    if parts.len() != 2
        || parts.iter().any(|p| p.is_empty())
        || !address.is_ascii()
        || address.len() > 254
        || address
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "<>,;:\"\\()".contains(c))
        || address == own
    {
        return;
    }
    if [
        "noreply",
        "no-reply",
        "do-not-reply",
        "donotreply",
        "mailer-daemon",
    ]
    .iter()
    .any(|word| parts[0].contains(word))
    {
        return;
    }
    if !address.contains(&query) && !folded(name).contains(&query) {
        return;
    }
    let entry = output.entry(address.clone()).or_insert_with(|| Ranked {
        contact: Contact {
            name: name.chars().take(200).collect(),
            address,
        },
        score: 0,
        recent,
    });
    if entry.contact.name.is_empty() && !name.is_empty() {
        entry.contact.name = name.chars().take(200).collect();
    }
    entry.score += weight;
    entry.recent = entry.recent.max(recent);
}

fn folded(value: &str) -> String {
    value
        .nfkd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed(store: &Store, account: &str, from: &str) {
        store
            .save_account(&Account {
                id: account.into(),
                email: format!("{account}@example.test"),
                provider: Provider::Gmail,
            })
            .unwrap();
        let raw = format!(
            "From: {from}\r\nTo: {account}@example.test\r\nSubject: Private body marker\r\n\r\nNever expose this body"
        );
        let message = crate::mime::parse(raw.as_bytes(), account, "original").unwrap();
        store.save(&message, Folder::Inbox).unwrap();
    }
    #[test]
    fn contact_sources_are_scoped() {
        let store = Store::open(":memory:").unwrap();
        seed(&store, "a", "\"Ada &amp; Co.\" <ada@example.test>");
        seed(&store, "b", "Other <another@example.test>");
        let values = store.contacts("a", "ada").unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].address, "ada@example.test");
        assert_eq!(values[0].name, "Ada & Co.");
        assert!(store.contacts("b", "ada").unwrap().is_empty());
        let mut draft = MailDraft {
            id: "contact-draft-operation".into(),
            account: "a".into(),
            kind: ComposeKind::New,
            original: None,
            to: vec!["colleague@example.test".into()],
            cc: vec![],
            bcc: vec!["private@example.test".into()],
            subject: "Body sentinel".into(),
            text: "Never expose this body".into(),
            headers: None,
            revision: 0,
        };
        draft.revision = store.save_mail_draft(&draft).unwrap();
        store.queue_send(&draft).unwrap();
        let values = store.contacts("a", "private").unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].address, "private@example.test");
        assert!(store.contacts("b", "private").unwrap().is_empty());
        let serialized = serde_json::to_string(&values).unwrap();
        assert!(!serialized.contains("Never expose"));
    }
    #[test]
    fn contact_queries_are_bounded() {
        let store = Store::open(":memory:").unwrap();
        seed(&store, "a", "No reply <noreply@example.test>");
        assert!(store.contacts("a", "noreply").unwrap().is_empty());
        assert!(store.contacts("a", "x").unwrap().is_empty());
        assert!(
            store
                .contacts("a", &"a".repeat(QUERY_BYTES + 1))
                .unwrap()
                .is_empty()
        );
        assert!(store.contacts("a", "\"} OR text:*").unwrap().is_empty());
    }
}
