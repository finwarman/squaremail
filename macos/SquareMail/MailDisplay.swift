import MessageText

extension Mail {
    var displaySubject: String { HeaderText.decode(subject) }
    var displayFrom: String { sender.isEmpty ? senderAddress : "\(displaySender) <\(senderAddress)>" }
    var displaySender: String { sender.isEmpty ? senderAddress : HeaderText.decode(sender) }
}
