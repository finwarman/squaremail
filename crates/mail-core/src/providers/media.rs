use super::*;
use crate::media::{ASSET_LIMIT, Asset, AssetSource, FILE_LIMIT};

fn encoded(id: &str) -> String {
    url::form_urlencoded::byte_serialize(id.as_bytes()).collect()
}
fn short(value: &str) -> String {
    value.chars().take(512).collect()
}

pub(crate) fn media_content(
    account: &Account,
    id: &str,
    context: &Context<'_>,
) -> Result<(String, Vec<Asset>)> {
    let (_, html) = body(account, id, context)?;
    let client = network::client()?;
    let token = oauth::access_token(account, context)?;
    let remote = encoded(id);
    let mut assets = Vec::new();
    match account.provider {
        Provider::Gmail => {
            let value = context
                .send(
                    client
                        .get(format!(
                            "{GMAIL_ROOT}/messages/{remote}?format=full&fields=payload"
                        ))
                        .bearer_auth(&token),
                )?
                .value;
            let mut pending = vec![(&value["payload"], 0)];
            let mut seen = 0;
            while let Some((part, depth)) = pending.pop() {
                seen += 1;
                if depth > 16 || seen > 128 {
                    return Err("Attachment MIME structure exceeds the limit".into());
                }
                let cid = part["headers"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|h| string(h, "name").eq_ignore_ascii_case("content-id"))
                    .and_then(|h| h["value"].as_str())
                    .map(|s| short(s.trim_matches(['<', '>'])));
                let name = string(part, "filename");
                if (!name.is_empty() || cid.is_some()) && assets.len() < ASSET_LIMIT {
                    let source = if let Some(id) = part["body"]["attachmentId"].as_str() {
                        AssetSource::Gmail { id: id.into() }
                    } else {
                        AssetSource::GmailPart {
                            id: string(part, "partId"),
                        }
                    };
                    assets.push(Asset {
                        id: mime::message_id("part", &string(part, "partId")),
                        name: short(if name.is_empty() {
                            "Inline image"
                        } else {
                            &name
                        }),
                        mime: string(part, "mimeType"),
                        size: part["body"]["size"].as_u64().unwrap_or(0),
                        cid,
                        source,
                    });
                }
                if let Some(children) = part["parts"].as_array() {
                    if pending.len() + children.len() > 128 {
                        return Err("Too many MIME parts".into());
                    }
                    pending.extend(children.iter().rev().map(|p| (p, depth + 1)));
                }
            }
        }
        Provider::Outlook => {
            let value=context.send(client.get(format!("{GRAPH_ROOT}/messages/{remote}/attachments?$select=id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId&$top={ASSET_LIMIT}")).bearer_auth(&token).header("Prefer","IdType=\"ImmutableId\""))?.value;
            for item in value["value"]
                .as_array()
                .ok_or("Attachment list is missing")?
                .iter()
                .take(ASSET_LIMIT)
            {
                if item["@odata.type"]
                    .as_str()
                    .is_some_and(|v| v != "#microsoft.graph.fileAttachment")
                {
                    continue;
                }
                let id = string(item, "id");
                assets.push(Asset {
                    id: mime::message_id("attachment", &id),
                    name: short(&string(item, "name")),
                    mime: string(item, "contentType"),
                    size: item["size"].as_u64().unwrap_or(0),
                    cid: item["contentId"].as_str().map(short),
                    source: AssetSource::Graph { id },
                });
            }
        }
        Provider::Local => {}
    }
    Ok((html, assets))
}

pub(crate) fn attachment_bytes(
    account: &Account,
    message: &str,
    source: &AssetSource,
    context: &Context<'_>,
) -> Result<Vec<u8>> {
    let client = network::client()?;
    let token = oauth::access_token(account, context)?;
    let message = encoded(message);
    let bytes = match source {
        AssetSource::Gmail { id } => {
            let value = context
                .send(
                    client
                        .get(format!(
                            "{GMAIL_ROOT}/messages/{message}/attachments/{}",
                            encoded(id)
                        ))
                        .bearer_auth(&token),
                )?
                .value;
            decode_url(value["data"].as_str().ok_or("Attachment content missing")?)?
        }
        AssetSource::GmailPart { id } => {
            let value = context
                .send(
                    client
                        .get(format!(
                            "{GMAIL_ROOT}/messages/{message}?format=full&fields=payload"
                        ))
                        .bearer_auth(&token),
                )?
                .value;
            let mut pending = vec![&value["payload"]];
            let mut data = None;
            let mut seen = 0;
            while let Some(part) = pending.pop() {
                seen += 1;
                if seen > 128 {
                    return Err("Too many MIME parts".into());
                }
                if part["partId"].as_str() == Some(id) {
                    data = part["body"]["data"].as_str();
                    break;
                }
                if let Some(parts) = part["parts"].as_array() {
                    if pending.len() + parts.len() > 128 {
                        return Err("Too many MIME parts".into());
                    }
                    pending.extend(parts);
                }
            }
            decode_url(data.ok_or("Inline attachment missing")?)?
        }
        AssetSource::Graph { id } => {
            let value = context
                .send(
                    client
                        .get(format!(
                            "{GRAPH_ROOT}/messages/{message}/attachments/{}?$select=microsoft.graph.fileAttachment/contentBytes",
                            encoded(id)
                        ))
                        .bearer_auth(&token)
                        .header("Prefer", "IdType=\"ImmutableId\""),
                )?
                .value;
            let content = value["contentBytes"]
                .as_str()
                .ok_or("Only file attachments can be previewed")?;
            if content.len() as u64 > FILE_LIMIT * 4 / 3 + 8 {
                return Err("Attachment exceeds the preview limit".into());
            }
            STANDARD.decode(content)?
        }
        _ => return Err("Attachment cannot be downloaded from this source".into()),
    };
    if bytes.len() as u64 > FILE_LIMIT {
        return Err("Attachment exceeds the 8 MiB preview limit".into());
    }
    Ok(bytes)
}
fn decode_url(value: &str) -> Result<Vec<u8>> {
    if value.len() as u64 > FILE_LIMIT * 4 / 3 + 8 {
        return Err("Attachment exceeds the preview limit".into());
    }
    Ok(URL_SAFE_NO_PAD
        .decode(value)
        .or_else(|_| URL_SAFE.decode(value))?)
}
