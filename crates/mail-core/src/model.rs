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
    SeedDemo,
    List {
        account: Option<String>,
        folder: Folder,
        query: String,
        offset: usize,
        limit: usize,
    },
    Message {
        id: String,
        mode: BodyMode,
    },
    Import {
        path: String,
    },
    Connect {
        provider: Provider,
        client_id: String,
        client_secret: Option<String>,
    },
    Sync {
        account: String,
        folder: Folder,
    },
}

#[derive(Debug, Deserialize)]
pub(crate) struct Request {
    pub(crate) database: String,
    #[serde(flatten)]
    pub(crate) command: Command,
}
