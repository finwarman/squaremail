import Foundation

enum ComposeKind: String, Codable { case new, reply, forward; case replyAll = "reply_all" }
struct ReplyHeaders: Codable {
    let to: [String]; let cc: [String]; let replyTo: [String]
    let messageID: String; let references: String; let thread: String
    private enum CodingKeys: String, CodingKey { case to, cc, references, thread; case replyTo = "reply_to"; case messageID = "message_id" }
}
struct MailDraft: Codable {
    let id: String
    var account: String
    let kind: ComposeKind
    let original: String?
    var to: [String]; var cc: [String]; var bcc: [String]
    var subject: String; var text: String
    let headers: ReplyHeaders?
    var revision: Int64
    func command() throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any] }
}
struct ComposeReply: Decodable {
    let draft: MailDraft
    let needsHeaders: Bool
    let attachmentsOmitted: Bool
    private enum CodingKeys: String, CodingKey { case draft; case needsHeaders = "needs_headers"; case attachmentsOmitted = "attachments_omitted" }
}
struct DraftReceipt: Decodable { let revision: Int64 }
struct QueuedSend { let id: String; let account: String }
struct MailWorkspace: Decodable {
    let drafts: [DraftSummary]; let work: [MailWorkSummary]
    let receipts: [MailWorkSummary]?
}
struct DraftSummary: Decodable { let id: String; let account: String; let subject: String; let updated: Int64; let revision: Int64 }
enum MailWorkKind: String, Decodable { case action, outbox }
enum MailWorkState: String, Decodable { case pending, sending, retry, blocked, uncertain, done }
enum MailWorkChoice: String { case retry, cancel, forget }
enum MailAccess: String { case changes, send }
struct MailWorkSummary: Decodable {
    let id: String; let account: String; let state: MailWorkState; let error: String?
    let attempts: Int; let remote: String?; let subject: String; let kind: MailWorkKind
}
enum MailActionKind: String { case read, flag, trash, archive, move }
