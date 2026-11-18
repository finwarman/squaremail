import Foundation

struct EventKey: Codable, Equatable {
    let account: String
    let calendar: String
    let id: String?
    var command: [String: Any] { ["account": account, "calendar": calendar, "id": id as Any? ?? NSNull()] }
}
struct EventTime: Codable, Equatable {
    enum Kind: String, Codable { case timed; case allDay = "all_day" }
    let kind: Kind
    let start: TimeValue
    let end: TimeValue
    let zone: String?
    enum TimeValue: Codable, Equatable {
        case instant(Int64), day(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int64.self) { self = .instant(number) }
            else { self = .day(try value.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self { case .instant(let number): try value.encode(number); case .day(let text): try value.encode(text) }
        }
    }
}
struct EventReminder: Codable {
    enum Kind: String, Codable { case preserve, off, minutes }
    let kind: Kind
    let minutes: Int?
}
struct EventDraft: Codable {
    let title: String
    let location: String
    let time: EventTime
    let reminder: EventReminder
}
struct EventDetail: Decodable {
    let key: EventKey
    let revision: String
    let draft: EventDraft
    let organizer: String
    let participants: [String]
    let participantCount: Int
    let conference: String
    let notes: String
    let recurring: Bool
    let writable: Bool
    private enum CodingKeys: String, CodingKey {
        case key, revision, draft, organizer, participants, conference, notes, recurring, writable
        case participantCount = "participant_count"
    }
}
struct EventDetailReply: Decodable { let detail: EventDetail? }
struct EventChange: Encodable {
    enum Updates: String, Encodable { case personal, notify }
    let operation: String
    let key: EventKey
    let revision: String?
    let draft: EventDraft
    let updates: Updates
    func command() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
struct EventWrite: Decodable {
    let operation: String
    let state: State
    let title: String
    let error: String?
    let account: String
    let calendar: String
    let id: String?
    enum State: String, Decodable { case pending, sending, retry, conflict, failed, done, uncertain }
}
struct AppNotice: Decodable {
    enum Kind: String, Decodable { case mail, reminder; case calendarUpdate = "calendar_update" }
    let id: String
    let account: String
    let kind: Kind
    let target: String
    let calendar: String?
    let title: String
    let detail: String
    let occurred: Int64
    let unread: Bool
}
struct NoticePlan: Decodable {
    let id: String
    let account: String
    let calendar: String
    let target: String
    let title: String
    let due: Int64
}
struct NoticePreference: Decodable { let account: String; let mail: Bool; let calendar: Bool }
struct NoticeBatch: Decodable {
    let items: [AppNotice]
    let banners: [AppNotice]
    let planned: [NoticePlan]
    let settings: [NoticePreference]
}
enum NoticeAction: String { case read, clear }
enum NoticeChannel: String { case mail, calendar }
enum NoticeToggle: String { case on, off }
enum NoticeDelivery: String { case quiet, desktop }

enum NotificationPermission { case allowed, denied }
