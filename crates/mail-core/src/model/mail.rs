use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(crate) struct ReplyHeaders {
    pub(crate) to: Vec<String>,
    pub(crate) cc: Vec<String>,
    pub(crate) reply_to: Vec<String>,
    pub(crate) message_id: String,
    pub(crate) references: String,
    pub(crate) thread: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum MailAction {
    Read {
        unread: bool,
    },
    Flag {
        flagged: bool,
    },
    Trash,
    Archive,
    Restore {
        snapshot: MailSnapshot,
    },
    Move {
        destination: String,
        source: Option<String>,
    },
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ComposeKind {
    New,
    Reply,
    ReplyAll,
    Forward,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct MailDraft {
    pub(crate) id: String,
    pub(crate) account: String,
    pub(crate) kind: ComposeKind,
    pub(crate) original: Option<String>,
    pub(crate) to: Vec<String>,
    pub(crate) cc: Vec<String>,
    pub(crate) bcc: Vec<String>,
    pub(crate) subject: String,
    pub(crate) text: String,
    pub(crate) headers: Option<ReplyHeaders>,
    pub(crate) revision: i64,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MailWorkState {
    Pending,
    Sending,
    Retry,
    Blocked,
    Uncertain,
    Done,
}
impl MailWorkState {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Sending => "sending",
            Self::Retry => "retry",
            Self::Blocked => "blocked",
            Self::Uncertain => "uncertain",
            Self::Done => "done",
        }
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MailAccess {
    Changes,
    Send,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MailWorkKind {
    Action,
    Outbox,
}
impl MailWorkKind {
    pub(crate) fn table(self) -> &'static str {
        match self {
            Self::Action => "mail_actions",
            Self::Outbox => "mail_outbox",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MailWorkChoice {
    Retry,
    Cancel,
    Forget,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct QueuedMail {
    pub(crate) operation: String,
    pub(crate) message: super::Message,
    pub(crate) action: MailAction,
    pub(crate) before: MailSnapshot,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct MailSnapshot {
    pub(crate) unread: bool,
    pub(crate) flagged: bool,
    pub(crate) folders: Vec<String>,
    pub(crate) memberships: Vec<String>,
}
#[derive(Debug)]
pub(crate) struct MailWork {
    pub(crate) id: String,
    pub(crate) account: String,
    pub(crate) data: String,
    pub(crate) attempts: i64,
    pub(crate) remote: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MailSendPhase {
    Ready,
    Creating,
    Prepared,
    Sending,
}

#[derive(Clone, Copy)]
pub(crate) enum MailActionLane {
    Read,
    Flag,
    Placement,
}
impl MailAction {
    pub(crate) fn lane(&self) -> MailActionLane {
        match self {
            Self::Read { .. } => MailActionLane::Read,
            Self::Flag { .. } => MailActionLane::Flag,
            _ => MailActionLane::Placement,
        }
    }
}
impl MailActionLane {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Flag => "flag",
            Self::Placement => "placement",
        }
    }
}

pub(crate) const REPLY_LIMIT: usize = 32 * 1024;
#[derive(Clone, Copy)]
pub(crate) enum MailToggle {
    On,
    Off,
}
impl From<bool> for MailToggle {
    fn from(value: bool) -> Self {
        if value { Self::On } else { Self::Off }
    }
}
impl MailToggle {
    pub(crate) fn enabled(self) -> bool {
        matches!(self, Self::On)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum MailEdit {
    Action { action: MailAction },
    Pin { pinned: bool },
}
