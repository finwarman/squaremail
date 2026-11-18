use crate::{Result, mime::message_id, model::*, network::Context, providers, store::Store};
use serde::{Deserialize, Serialize};
use std::{
    borrow::Cow,
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    net::{IpAddr, ToSocketAddrs},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use url::Url;

pub(crate) const FILE_LIMIT: u64 = 8 * 1024 * 1024;
pub(crate) const ASSET_LIMIT: usize = 32;
const IMAGE_LIMIT: usize = 12;
const CACHE_LIMIT: u64 = 128 * 1024 * 1024;
const CACHE_COUNT: usize = 512;
const HTTP_OK: u16 = 200;
const IMAGE_SCHEME: &str = "squaremail-image";
static CACHE_WORKER: Mutex<()> = Mutex::new(());
mod office;

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PreviewMode {
    Thumbnail,
    Reader,
    Document,
}
impl PreviewMode {
    fn pixels(self) -> u16 {
        match self {
            Self::Thumbnail => 320,
            Self::Reader => 1024,
            Self::Document => 0,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum AssetSource {
    Remote { url: String },
    Gmail { id: String },
    GmailPart { id: String },
    Graph { id: String },
    Local,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Asset {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) mime: String,
    pub(crate) size: u64,
    pub(crate) cid: Option<String>,
    pub(crate) source: AssetSource,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Manifest {
    pub(crate) html: String,
    pub(crate) assets: Vec<Asset>,
    pub(crate) image_ids: Vec<String>,
}

pub(crate) fn manifest(
    store: &Store,
    id: &str,
    mode: BodyMode,
    context: &Context<'_>,
) -> Result<Option<Manifest>> {
    if let Some(value) = store.media(id)? {
        return Ok(Some(value));
    }
    if matches!(mode, BodyMode::Cached) {
        return Ok(None);
    }
    let message = store.message(id)?;
    let account = account(store, &message.account_id)?;
    if account.provider == Provider::Local {
        if message.has_attachments {
            return Err("Re-import this local email to discover its attachments".into());
        }
        return Ok(Some(prepare(
            message.html.as_deref().unwrap_or(""),
            Vec::new(),
        )));
    }
    if !store.connected(&account.id)? {
        return Err("Reconnect this account to discover message images and attachments".into());
    }
    let (html, assets) = providers::media_content(&account, &message.remote_id, context)?;
    if html.len() as u64 > FILE_LIMIT {
        return Err("HTML exceeds the media preview limit".into());
    }
    context.check()?;
    let value = prepare(&html, assets);
    store.save_media(id, &value)?;
    Ok(Some(value))
}

fn account(store: &Store, id: &str) -> Result<Account> {
    store
        .accounts()?
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "Account not found".into())
}

pub(crate) fn prepare(html: &str, attachments: Vec<Asset>) -> Manifest {
    let assets = Arc::new(Mutex::new(attachments));
    let images = Arc::new(Mutex::new(BTreeMap::<String, String>::new()));
    let output = images.clone();
    let collected = assets.clone();
    let references = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut builder = ammonia::Builder::default();
    builder.rm_tags(&[
        "style", "form", "input", "button", "video", "audio", "source",
    ]);
    builder.url_schemes(
        ["https", "http", "mailto", "cid", IMAGE_SCHEME]
            .into_iter()
            .collect(),
    );
    builder.url_relative(ammonia::UrlRelative::Deny);
    builder.rm_tag_attributes("img", &["width", "height", "srcset"]);
    for tag in ["table", "tr", "td", "th"] {
        builder.rm_tag_attributes(tag, &["height", "width", "cellpadding", "cellspacing"]);
    }
    builder.attribute_filter(move |tag, attr, value| {
        if tag != "img" || attr != "src" {
            return Some(Cow::Borrowed(value));
        }
        if references.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= IMAGE_LIMIT {
            return None;
        }
        let mut images = output.lock().ok()?;
        if let Some(id) = images.get(value) {
            return Some(Cow::Owned(format!("{IMAGE_SCHEME}://asset/{id}")));
        }
        if images.len() >= IMAGE_LIMIT {
            return None;
        }
        let mut assets = collected.lock().ok()?;
        let id = if let Some(cid) = value.strip_prefix("cid:") {
            assets
                .iter()
                .find(|a| a.cid.as_deref() == Some(cid) && a.mime.starts_with("image/"))?
                .id
                .clone()
        } else {
            let url = remote_url(value).ok()?;
            let id = message_id("image", url.as_str());
            assets.push(Asset {
                id: id.clone(),
                name: "Remote image".into(),
                mime: "image/*".into(),
                size: 0,
                cid: None,
                source: AssetSource::Remote { url: url.into() },
            });
            id
        };
        images.insert(value.into(), id.clone());
        Some(Cow::Owned(format!("{IMAGE_SCHEME}://asset/{id}")))
    });
    let safe = builder.clean(html).to_string();
    let image_ids = images.lock().unwrap().values().cloned().collect();
    let list = assets.lock().unwrap().clone();
    Manifest {
        html: safe,
        assets: list,
        image_ids,
    }
}

pub(crate) fn cache_root(database: &str) -> PathBuf {
    let path = Path::new(database);
    path.with_file_name(format!(
        "{}.media",
        path.file_name().unwrap_or_default().to_string_lossy()
    ))
}
fn asset_path(database: &str, account: &str, message: &str, asset: &str) -> PathBuf {
    cache_root(database)
        .join(message_id("account", account))
        .join(format!("{}.bin", message_id(message, asset)))
}
pub(crate) fn remove_cache(database: &str, account: &str) -> Result<()> {
    let _guard = CACHE_WORKER.lock().map_err(|_| "Media cache lock failed")?;
    let path = cache_root(database).join(message_id("account", account));
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    Ok(())
}

pub(crate) fn file(
    store: &Store,
    database: &str,
    id: &str,
    asset_id: &str,
    preview: PreviewMode,
    context: &Context<'_>,
) -> Result<serde_json::Value> {
    // Serial publication keeps temporary downloads and cache eviction bounded.
    let _guard = CACHE_WORKER.lock().map_err(|_| "Media cache lock failed")?;
    context.check()?;
    let message = store.message(id)?;
    let manifest = store
        .media(id)?
        .ok_or("Discover this message's media first")?;
    let asset = manifest
        .assets
        .iter()
        .find(|a| a.id == asset_id)
        .ok_or("Attachment is not part of this message")?;
    if !previewable(&asset.mime) {
        return Err("Preview supports raster images, PDF, DOCX and XLSX".into());
    }
    if asset.size > FILE_LIMIT {
        return Err("Preview exceeds the 8 MiB download limit".into());
    }
    let path = asset_path(database, &message.account_id, id, asset_id);
    let document = matches!(preview, PreviewMode::Document);
    let normalized = if document {
        path.with_extension(extension(&asset.mime)?)
    } else {
        path.with_extension(format!("{}.png", preview.pixels()))
    };
    if normalized.is_file() {
        fs::OpenOptions::new()
            .write(true)
            .open(&normalized)?
            .set_modified(std::time::SystemTime::now())?;
        return Ok(
            serde_json::json!({"path":if document {&normalized}else{&path},"mime":asset.mime}),
        );
    }
    if !path.is_file() {
        let account = account(store, &message.account_id)?;
        if matches!(asset.source, AssetSource::Remote { .. }) {
            if let AssetSource::Remote { url } = &asset.source {
                download(url, &path, context)?;
            }
        } else {
            if !store.connected(&account.id)? {
                return Err("Offline attachment is not cached. Reconnect to download it.".into());
            }
            let bytes =
                providers::attachment_bytes(&account, &message.remote_id, &asset.source, context)?;
            publish(&path, &bytes)?;
        }
        context.check()?;
        trim_cache(&cache_root(database), &path)?;
    }
    // Cache reads update recency without retaining file contents in the application API.
    let file = fs::OpenOptions::new().write(true).open(&path)?;
    file.set_modified(std::time::SystemTime::now())?;
    office::validate(&path, &asset.mime, context)?;
    if document {
        fs::hard_link(&path, &normalized)?;
        trim_cache(&cache_root(database), &normalized)?;
        return Ok(serde_json::json!({"path":normalized,"mime":asset.mime}));
    }
    Ok(serde_json::json!({"path":path,"mime":asset.mime}))
}

pub(crate) fn previewable(mime: &str) -> bool {
    matches!(
        mime,
        "image/*"
            | "image/png"
            | "image/jpeg"
            | "image/gif"
            | "image/webp"
            | "image/tiff"
            | "image/heic"
            | "image/heif"
            | "application/pdf"
    ) || mime == office::DOCX
        || mime == office::XLSX
}
fn extension(mime: &str) -> Result<&'static str> {
    Ok(match mime {
        "application/pdf" => "pdf",
        office::DOCX => "docx",
        office::XLSX => "xlsx",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/tiff" => "tiff",
        "image/heic" | "image/heif" => "heic",
        _ => return Err("Unsupported document preview format".into()),
    })
}
pub(crate) fn import_media(
    store: &Store,
    database: &str,
    message: &Message,
    raw: &[u8],
) -> Result<()> {
    use mail_parser::{MessageParser, MimeHeaders};
    let parsed = MessageParser::default()
        .parse(raw)
        .ok_or("Invalid MIME email")?;
    let mut assets = Vec::new();
    for (index, part) in parsed.attachments().take(ASSET_LIMIT).enumerate() {
        let mime = part
            .content_type()
            .map(|t| {
                format!(
                    "{}/{}",
                    t.c_type,
                    t.c_subtype.as_deref().unwrap_or("octet-stream")
                )
            })
            .unwrap_or_else(|| "application/octet-stream".into());
        let id = message_id("local-part", &index.to_string());
        if previewable(&mime) && part.contents().len() as u64 <= FILE_LIMIT {
            publish(
                &asset_path(database, &message.account_id, &message.id, &id),
                part.contents(),
            )?;
        }
        assets.push(Asset {
            id,
            name: part
                .attachment_name()
                .unwrap_or("Inline image")
                .chars()
                .take(512)
                .collect(),
            mime,
            size: part.contents().len() as u64,
            cid: part.content_id().map(String::from),
            source: AssetSource::Local,
        });
    }
    let html = parsed.body_html(0).unwrap_or_default();
    if html.len() as u64 > FILE_LIMIT {
        return Err("HTML exceeds the media preview limit".into());
    }
    let manifest = prepare(&html, assets);
    store.save_media(&message.id, &manifest)?;
    let root = cache_root(database);
    if root.exists() {
        trim_cache(&root, Path::new(""))?;
    }
    Ok(())
}
pub(crate) fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if bytes.len() as u64 > FILE_LIMIT {
        return Err("Preview exceeds the 8 MiB download limit".into());
    }
    let parent = path.parent().ok_or("Invalid cache path")?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let temporary = path.with_extension("partial");
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(bytes)?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
fn trim_cache(root: &Path, keep: &Path) -> Result<()> {
    let mut files = Vec::new();
    for dir in fs::read_dir(root)? {
        let dir = dir?;
        if !dir.file_type()?.is_dir() {
            continue;
        }
        for file in fs::read_dir(dir.path())? {
            let file = file?;
            let meta = file.metadata()?;
            if meta.is_file() {
                files.push((meta.modified()?, meta.len(), file.path()));
            }
        }
    }
    files.sort_by_key(|f| (f.2.extension().is_some_and(|e| e == "png"), f.0));
    let mut bytes: u64 = files.iter().map(|f| f.1).sum();
    let mut count = files.len();
    for (_, size, path) in files {
        if bytes <= CACHE_LIMIT && count <= CACHE_COUNT {
            break;
        }
        if path == keep {
            continue;
        }
        if fs::remove_file(path).is_ok() {
            bytes = bytes.saturating_sub(size);
            count -= 1;
        }
    }
    Ok(())
}

fn remote_url(raw: &str) -> Result<Url> {
    if raw.len() > 4096 {
        return Err("Image URL is too long".into());
    }
    let url = Url::parse(raw)?;
    let host = url.host_str().ok_or("Image URL has no host")?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || host.ends_with(".local")
        || host == "localhost"
        || !host.contains('.') && !host.contains(':')
    {
        return Err("Only public HTTPS image URLs are allowed".into());
    }
    Ok(url)
}
fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [a, b, c, _] = ip.octets();
            !(a == 0
                || a == 10
                || a == 127
                || a >= 224
                || (a == 100 && (64..=127).contains(&b))
                || (a == 169 && b == 254)
                || (a == 172 && (16..=31).contains(&b))
                || (a == 192 && (b == 168 || b == 0 || b == 2))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113))
        }
        IpAddr::V6(ip) => {
            if let Some(ip) = ip.to_ipv4_mapped() {
                return public_ip(IpAddr::V4(ip));
            }
            // Only ordinary global unicast. Excludes local, multicast, NAT64 and tunnels.
            let s = ip.segments();
            (s[0] & 0xe000) == 0x2000
                && s[0] != 0x2002
                && !(s[0] == 0x2001 && (s[1] < 0x200 || s[1] == 0xdb8))
        }
    }
}
fn download(raw: &str, path: &Path, context: &Context<'_>) -> Result<()> {
    let url = remote_url(raw)?;
    let host = url.host_str().ok_or("Image host missing")?;
    // Resolve off the UI thread, validate every address, then pin this connection to them.
    let addresses = resolve(host)?;
    context.check()?;
    if addresses.is_empty() || addresses.iter().any(|a| !public_ip(a.ip())) {
        return Err("Private and reserved image addresses are blocked".into());
    }
    let client = reqwest::blocking::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(10))
        .resolve_to_addrs(host, &addresses)
        .build()?;
    let response = client
        .get(url)
        .header("Accept", "image/png,image/jpeg,image/gif,image/webp")
        .send()
        .map_err(|_| "Image download failed or timed out")?;
    if response.status().as_u16() != HTTP_OK {
        return Err("Image server rejected the request or redirected it".into());
    }
    let mime = response
        .headers()
        .get("Content-Type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("");
    if !mime.starts_with("image/") || !previewable(mime) || mime == "image/*" {
        return Err("Remote resource is not a supported raster image".into());
    }
    let mut bytes = Vec::new();
    response.take(FILE_LIMIT + 1).read_to_end(&mut bytes)?;
    context.check()?;
    publish(path, &bytes)
}

fn resolve(host: &str) -> Result<Vec<std::net::SocketAddr>> {
    use std::sync::{OnceLock, mpsc};
    type Lookup = (String, mpsc::SyncSender<Vec<std::net::SocketAddr>>);
    static RESOLVER: OnceLock<mpsc::SyncSender<Lookup>> = OnceLock::new();
    let sender = RESOLVER.get_or_init(|| {
        let (sender, receiver) = mpsc::sync_channel::<Lookup>(1);
        std::thread::spawn(move || {
            while let Ok((host, reply)) = receiver.recv() {
                let addresses = (host.as_str(), 443)
                    .to_socket_addrs()
                    .map(|a| a.take(32).collect())
                    .unwrap_or_default();
                let _ = reply.send(addresses);
            }
        });
        sender
    });
    let (reply, receiver) = mpsc::sync_channel(1);
    sender
        .try_send((host.to_string(), reply))
        .map_err(|_| "Image DNS resolver is busy")?;
    receiver
        .recv_timeout(Duration::from_secs(3))
        .map_err(|_| "Image DNS lookup timed out".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn images_are_capabilities() {
        let manifest = prepare(
            "<script>bad()</script><img src='https://cdn.example.com/a.png' width='9999' onerror='bad()'><img src='https://cdn.example.com/a.png'><img src='http://tracker.example.com/x'><img src='data:image/svg+xml,bad'><td height='900'>Text</td><iframe src='https://evil.example.com'></iframe>",
            Vec::new(),
        );
        assert_eq!(manifest.assets.len(), 1);
        assert_eq!(manifest.image_ids.len(), 1);
        assert!(manifest.html.contains("squaremail-image://asset/"));
        for forbidden in [
            "https://", "http://", "data:", "onerror", "9999", "900", "<script", "<iframe",
        ] {
            assert!(!manifest.html.contains(forbidden), "{}", manifest.html);
        }
        let inputs = (0..40)
            .map(|i| format!("<img src='https://cdn.example.com/{i}'>"))
            .collect::<String>();
        assert_eq!(prepare(&inputs, Vec::new()).image_ids.len(), IMAGE_LIMIT);
    }
    #[test]
    fn private_destinations_blocked() {
        for ip in [
            "127.0.0.1",
            "10.2.3.4",
            "169.254.169.254",
            "100.64.1.2",
            "192.168.1.1",
            "::1",
            "::ffff:127.0.0.1",
            "fc00::1",
            "2001:db8::1",
            "64:ff9b::1",
            "2002:7f00:1::",
        ] {
            assert!(!public_ip(ip.parse().unwrap()), "{ip}");
        }
        for ip in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] {
            assert!(public_ip(ip.parse().unwrap()));
        }
        for url in [
            "http://example.com/x",
            "https://user:secret@example.com/x",
            "https://example.com:8443/x",
            "https://localhost/x",
            "https://printer.local/x",
            "file:///etc/passwd",
        ] {
            assert!(remote_url(url).is_err());
        }
    }
    #[test]
    fn cache_eviction_is_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let account = dir.path().join("account");
        fs::create_dir(&account).unwrap();
        let old = account.join("old.bin");
        let kept = account.join("new.320.png");
        fs::File::create(&old)
            .unwrap()
            .set_len(CACHE_LIMIT + 1)
            .unwrap();
        fs::write(&kept, b"thumbnail").unwrap();
        trim_cache(dir.path(), &kept).unwrap();
        assert!(!old.exists());
        assert!(kept.exists());
        for index in 0..CACHE_COUNT {
            fs::write(account.join(format!("{index}.bin")), b"x").unwrap();
        }
        trim_cache(dir.path(), &kept).unwrap();
        assert_eq!(fs::read_dir(&account).unwrap().count(), CACHE_COUNT);
        assert!(kept.exists());
    }
    #[test]
    fn local_assets_survive_restart() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("mail.sqlite");
        let store = Store::open(db.to_str().unwrap()).unwrap();
        let account = Account {
            id: "local".into(),
            email: "Imports".into(),
            provider: Provider::Local,
        };
        store.save_account(&account).unwrap();
        let raw=b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/html\r\n\r\n<img src='cid:photo'><b>safe</b>\r\n--x\r\nContent-Type: image/png\r\nContent-ID: <photo>\r\nContent-Disposition: attachment; filename=photo.png\r\nContent-Transfer-Encoding: base64\r\n\r\naGVsbG8=\r\n--x--\r\n";
        let message = crate::mime::parse(raw, "local", "one").unwrap();
        store.save(&message, Folder::Inbox).unwrap();
        import_media(&store, db.to_str().unwrap(), &message, raw).unwrap();
        let manifest = store.media(&message.id).unwrap().unwrap();
        assert_eq!(manifest.assets.len(), 1);
        assert_eq!(manifest.image_ids.len(), 1);
        drop(store);
        let store = Store::open(db.to_str().unwrap()).unwrap();
        let context = Context::new(None, 5);
        let file = file(
            &store,
            db.to_str().unwrap(),
            &message.id,
            &manifest.assets[0].id,
            PreviewMode::Thumbnail,
            &context,
        )
        .unwrap();
        assert_eq!(fs::read(file["path"].as_str().unwrap()).unwrap(), b"hello");
        assert!(
            super::file(
                &store,
                db.to_str().unwrap(),
                &message.id,
                "other-account",
                PreviewMode::Thumbnail,
                &context
            )
            .is_err()
        );
        assert!(publish(&dir.path().join("huge"), &vec![0; FILE_LIMIT as usize + 1]).is_err());
    }
}
