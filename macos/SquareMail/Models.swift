import Foundation

enum Provider: String, Codable { case gmail, outlook, local }
enum Folder: String, CaseIterable {
    case inbox, unread, starred, sent, drafts, archive, trash, all

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .unread: return "Unread mail"
        case .starred: return "Starred"
        case .sent: return "Sent items"
        case .drafts: return "Drafts"
        case .archive: return "Archive"
        case .trash: return "Deleted items"
        case .all: return "All cached mail"
        }
    }
}

enum ReaderMode { case text, html }
enum ReadingLayout: String { case below, right }
enum MailSearchMode: String { case literal, smart }
enum MailSearchScope: Int { case folder, allFolders }
enum MailSearchMatch: String, Decodable { case literal, approximate, none }
struct MailSearchPage: Decodable { let messages: [Mail]; let kind: MailSearchMatch }
enum MailboxMode { case demo, live }
enum WorkQueue { case local, network, sync, login, media, calendar, notifications }

struct Account: Decodable {
    let id: String
    let email: String
    let provider: Provider
    let connected: Bool?
}

struct Mail: Decodable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case id, pinned
        case keepUnread = "keep_unread"
        case accountId = "account_id"
        case remoteId = "remote_id"
        case sender
        case senderAddress = "sender_address"
        case recipient
        case subject
        case preview
        case timestamp
        case unread
        case starred
        case hasAttachments = "has_attachments"
        case text
        case html
    }

    let id: String
    let pinned: Bool?
    let keepUnread: Bool?
    let accountId: String
    let remoteId: String
    let sender: String
    let senderAddress: String
    let recipient: String
    let subject: String
    let preview: String
    let timestamp: Int64
    let unread: Bool
    let starred: Bool
    let hasAttachments: Bool
    let text: String?
    let html: String?
}

struct EmptyReply: Decodable {}
struct SyncReply: Decodable { let count: Int }

struct MailError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MailFolder: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case id
        case name
        case parentId = "parent_id"
        case system
    }

    let accountId: String
    let id: String
    let name: String
    let parentId: String?
    let system: String?
}
struct CalendarSource: Decodable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case id
        case name
        case color
        case isPrimary = "is_primary"
    }

    let accountId: String
    let id: String
    let name: String
    let color: String
    let isPrimary: Bool
    var key: String { accountId + ":" + id }
}
struct CalendarEvent: Decodable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case calendarId = "calendar_id"
        case id
        case title
        case start
        case end
        case allDay = "all_day"
        case startDay = "start_day"
        case endDay = "end_day"
        case location
    }

    let accountId: String
    let calendarId: String
    let id: String
    let title: String
    let start: Int64
    let end: Int64
    let allDay: Bool
    let startDay: String?
    let endDay: String?
    let location: String
    var sourceKey: String { accountId + ":" + calendarId }
}
struct SyncStep: Decodable {
    private enum CodingKeys: String, CodingKey {
        case worked, more
        case bodyCached = "body_cached"
        case bodyTotal = "body_total"
        case accountId = "account_id"
        case kind
        case error
        case retryAfter = "retry_after"
    }

    let bodyCached: Int?
    let bodyTotal: Int?
    let more: Bool?
    let worked: Bool
    let accountId: String?
    let kind: SyncKind?
    let error: String?
    let retryAfter: Int?
    init(worked: Bool, accountId: String?, kind: SyncKind?, error: String?, retryAfter: Int?, more: Bool? = nil, bodyCached: Int? = nil, bodyTotal: Int? = nil) {
        self.bodyCached = bodyCached; self.bodyTotal = bodyTotal
        self.worked = worked; self.accountId = accountId; self.kind = kind; self.error = error; self.retryAfter = retryAfter; self.more = more
    }
}
struct ClientConfig: Decodable {
    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case configured
    }

    let clientId: String
    let configured: Bool
}
struct SyncStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case kind
        case resource
        case window
        case lastSuccess = "last_success"
        case nextDue = "next_due"
        case error
    }

    let accountId: String
    let kind: SyncKind
    let resource: String
    let window: Int64
    let lastSuccess: Int64?
    let nextDue: Int64
    let error: String?
}

enum BackfillMode: String, Decodable { case enabled, paused }
struct BackfillConfig: Decodable { let mode: BackfillMode }

enum SyncKind: String, Decodable { case catalog, mail, calendar; case bodyBackfill = "body_backfill"; case recentMail = "recent_mail" }

enum CoreCommand: String {
    case searchMail = "search_mail"
    case compose
    case moveFolders = "move_folders"
    case queueMail = "queue_mail"
    case bodyBackfill = "body_backfill"
    case readMail = "read_mail"
    case pinMail = "pin_mail"
    case saveMailDraft = "save_mail_draft"
    case mailDraft = "mail_draft"
    case mailWorkspace = "mail_workspace"
    case deleteMailDraft = "delete_mail_draft"
    case sendMail = "send_mail"
    case mailWork = "mail_work"
    case mailConsent = "mail_consent"
    case accounts, calendars, configure, connect, disconnect, events, folders, list, message
    case importMail = "import"
    case calendarWindows = "calendar_windows"
    case clientConfig = "client_config"
    case importClient = "import_client"
    case seedDemo = "seed_demo"
    case refreshAccount = "refresh_account"
    case syncNext = "sync_next"
    case syncNow = "sync_now"
    case notices
    case noticeAction = "notice_action"
    case noticeSetting = "notice_setting"
    case eventDetail = "event_detail"
    case queueEvent = "queue_event"
    case saveEventDraft = "save_event_draft"
    case eventWrites = "event_writes"
    case discardEvent = "discard_event"
    case calendarConsent = "calendar_consent"
    case media
    case mediaFile = "media_file"
}
enum ImagePermission { case blocked, loaded }
enum PreviewSize: String, Sendable {
    case thumbnail, reader, document
    var pixels: Int { self == .thumbnail ? 320 : 1024 }
}
struct MediaReply: Decodable { let manifest: MediaManifest? }
struct MediaManifest: Decodable {
    let html: String
    let assets: [MediaAsset]
    let imageIDs: [String]
    private enum CodingKeys: String, CodingKey { case html, assets; case imageIDs = "image_ids" }
}
struct MediaAsset: Decodable {
    let id: String
    let name: String
    let mime: String
    let size: UInt64
    let source: Source
    struct Source: Decodable { let kind: Kind }
    enum Kind: String, Decodable { case remote, gmail, graph, local; case gmailPart = "gmail_part" }
    var previewable: Bool { size <= 8 * 1024 * 1024 && (documentType != nil || ["image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff", "image/heic", "image/heif"].contains(mime)) }
    var documentType: DocumentType? { DocumentType(rawValue: mime) }
}
enum DocumentType: String {
    case pdf = "application/pdf"
    case docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
}
struct MediaFile: Decodable, Sendable { let path: String; let mime: String }
enum BodyFetch: String { case cached, fetch }
enum AccountDisconnect: String { case keepCache = "keep_cache", removeCache = "remove_cache" }
