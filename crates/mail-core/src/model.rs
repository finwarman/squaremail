use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Provider {
    Gmail,
    Outlook,
    Local,
}

impl Provider {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Gmail => "gmail",
            Self::Outlook => "outlook",
            Self::Local => "local",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Folder {
    Inbox,
    Sent,
    Drafts,
    Archive,
    Trash,
    All,
    Unread,
    Starred,
}

impl Folder {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Inbox => "inbox",
            Self::Sent => "sent",
            Self::Drafts => "drafts",
            Self::Archive => "archive",
            Self::Trash => "trash",
            Self::All => "all",
            Self::Unread => "unread",
            Self::Starred => "starred",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Account {
    pub(crate) id: String,
    pub(crate) email: String,
    pub(crate) provider: Provider,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Message {
    pub(crate) id: String,
    pub(crate) account_id: String,
    pub(crate) remote_id: String,
    pub(crate) sender: String,
    pub(crate) sender_address: String,
    pub(crate) recipient: String,
    pub(crate) subject: String,
    pub(crate) preview: String,
    pub(crate) timestamp: i64,
    pub(crate) unread: bool,
    pub(crate) starred: bool,
    pub(crate) has_attachments: bool,
    pub(crate) text: Option<String>,
    pub(crate) html: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BodyMode {
    Cached,
    Fetch,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub(crate) enum Command {
    Accounts,
    ClientConfig {
        provider: Provider,
    },
    Configure {
        provider: Provider,
        client_id: String,
        client_secret: Option<String>,
    },
    ImportClient {
        path: String,
    },
    Folders {
        account: String,
    },
    Disconnect {
        account: String,
        mode: DisconnectMode,
    },
    RefreshAccount {
        account: String,
    },
    SyncNext,
    SyncNow,
    SyncStatus,
    EventDetail {
        key: crate::calendar::EventKey,
        mode: BodyMode,
    },
    QueueEvent {
        change: crate::calendar::EventChange,
    },
    EventWrites,
    DiscardEvent {
        operation: String,
    },
    CalendarConsent {
        account: String,
    },
    Notices {
        delivery: crate::notices::NoticeDelivery,
    },
    NoticeAction {
        action: crate::notices::NoticeAction,
        id: Option<String>,
    },
    NoticeSetting {
        account: Option<String>,
        channel: crate::notices::NoticeChannel,
        toggle: crate::notices::Toggle,
    },
    Calendars,
    Events {
        start: i64,
        end: i64,
        offset: usize,
        limit: usize,
    },
    CalendarWindows {
        months: Vec<i64>,
    },
    CalendarWindow {
        month: i64,
    },
    SeedDemo,
    List {
        account: Option<String>,
        folder: Folder,
        folder_id: Option<String>,
        query: String,
        offset: usize,
        limit: usize,
    },
    Message {
        id: String,
        mode: BodyMode,
    },
    Media {
        id: String,
        mode: BodyMode,
    },
    MediaFile {
        id: String,
        asset: String,
        preview: crate::media::PreviewMode,
    },
    Import {
        path: String,
    },
    Connect {
        provider: Provider,
        client_id: String,
        client_secret: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
pub(crate) struct Request {
    pub(crate) database: String,
    #[serde(flatten)]
    pub(crate) command: Command,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum DisconnectMode {
    KeepCache,
    RemoveCache,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct MailFolder {
    pub(crate) account_id: String,
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) parent_id: Option<String>,
    pub(crate) system: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct CalendarSource {
    pub(crate) account_id: String,
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) color: String,
    pub(crate) is_primary: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct CalendarEvent {
    #[serde(default)]
    pub(crate) reminder_times: Vec<i64>,
    #[serde(default)]
    pub(crate) version: i64,
    pub(crate) account_id: String,
    pub(crate) calendar_id: String,
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) start: i64,
    pub(crate) end: i64,
    pub(crate) all_day: bool,
    pub(crate) start_day: Option<String>,
    pub(crate) end_day: Option<String>,
    pub(crate) location: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum JobKind {
    RecentMail,
    Catalog,
    Mail,
    Calendar,
}
impl JobKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::RecentMail => "recent_mail",
            Self::Catalog => "catalog",
            Self::Mail => "mail",
            Self::Calendar => "calendar",
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct SyncJob {
    pub(crate) account_id: String,
    pub(crate) kind: JobKind,
    pub(crate) resource: String,
    pub(crate) window: i64,
    pub(crate) state: serde_json::Value,
    pub(crate) failures: i64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum RetryClass {
    Network,
    Throttled,
    Auth,
}
impl RetryClass {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Network => "network",
            Self::Throttled => "throttled",
            Self::Auth => "auth",
        }
    }
}
