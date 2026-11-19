import Foundation

enum ReadHoldProbe: String { case create, reopen }

enum AutomaticRead: String { case afterDelay, manual }
enum ReadExposure { case viewing, hidden }
enum UnreadHold { case keep, automatic }
enum MailReadState: String { case read, unread = "keep_unread", automatic }

@MainActor
final class ReadDwell {
    var onElapsed: ((String) -> Bool)?
    private(set) var heldID: String?
    private var selectedID: String?
    private var firedID: String?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var mode = AutomaticRead.afterDelay
    private let delay: Duration
    var hasPending: Bool { task != nil }

    init(delay: Duration = .seconds(2)) { self.delay = delay }
    func select(_ id: String?) {
        guard id != selectedID else { return }
        cancel(); selectedID = id; heldID = nil; firedID = nil
    }
    func setMode(_ value: AutomaticRead) {
        guard mode != value else { return }
        mode = value; firedID = nil; cancel()
    }
    func setHold(_ value: UnreadHold) {
        heldID = value == .keep ? selectedID : nil
        firedID = nil; cancel()
    }
    func update(_ exposure: ReadExposure) {
        guard exposure == .viewing, mode == .afterDelay, let id = selectedID, heldID != id, firedID != id else { cancel(); return }
        guard task == nil else { return }
        let generation = revision
        task = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == revision, selectedID == id else { return }
            task = nil
            if onElapsed?(id) == true { firedID = id }
        }
    }
    func cancel() { revision += 1; task?.cancel(); task = nil }
    deinit { task?.cancel() }

    static func verify() async throws {
        let reader = ReadDwell(delay: .milliseconds(30))
        var seen: [String] = []
        reader.onElapsed = { seen.append($0); return true }
        reader.select("old"); reader.update(.viewing)
        reader.select("current"); reader.update(.viewing)
        try await Task.sleep(for: .milliseconds(60))
        guard seen == ["current"], !reader.hasPending else { throw MailError(message: "Read delay kept a stale selection or repeated") }
        reader.select("held"); reader.setHold(.keep); reader.update(.viewing)
        guard !reader.hasPending else { throw MailError(message: "Keep unread started a read timer") }
        reader.setHold(.automatic); reader.setMode(.manual); reader.update(.viewing)
        guard !reader.hasPending else { throw MailError(message: "Manual reading started a timer") }
        reader.setMode(.afterDelay); reader.update(.viewing); reader.update(.hidden)
        try await Task.sleep(for: .milliseconds(60))
        guard seen == ["current"], !reader.hasPending else { throw MailError(message: "Hidden reading did not cancel its delay") }
        weak var retired: ReadDwell?
        do {
            let value = ReadDwell(); retired = value
            value.select("released"); value.update(.viewing)
        }
        guard retired == nil else { throw MailError(message: "Read delay retained its owner") }
    }
}

extension Mail {
    func keepingBody(_ body: Mail) -> Mail {
        copyRead(unread ? .unread : .read, body: body)
    }
    private func copyRead(_ state: MailReadState, body: Mail) -> Mail {
        Mail(id: id, pinned: pinned, keepUnread: keepUnread, accountId: accountId, remoteId: remoteId, sender: sender, senderAddress: senderAddress,
             recipient: recipient, subject: subject, preview: preview, timestamp: timestamp, unread: state == .unread,
             starred: starred, hasAttachments: hasAttachments, text: body.text, html: body.html)
    }
}
