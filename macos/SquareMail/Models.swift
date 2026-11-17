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
enum MailboxMode { case demo, live }
enum WorkQueue { case local, network }

struct Account: Decodable {
    let id: String
    let email: String
    let provider: Provider
}

struct Mail: Decodable {
    let id: String
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
