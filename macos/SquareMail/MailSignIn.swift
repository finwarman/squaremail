import Foundation

enum SignInPurpose: Equatable {
    case mail(MailAccess), connect(Provider)
    var title: String {
        switch self {
        case .mail(.send): return "Enable sending"
        case .mail(.changes): return "Enable mail changes"
        case .connect(.gmail): return "Connect Gmail"
        case .connect(.outlook): return "Connect Outlook / Microsoft 365"
        case .connect(.local): return "Connect account"
        }
    }
}
struct SignInContext: Equatable {
    let account: String
    let purpose: SignInPurpose
}
enum MailSignIn: Equatable {
    case idle, waiting(SignInContext), cancelling(SignInContext), failed(SignInContext, String)
    var context: SignInContext? {
        switch self { case .idle: return nil; case .waiting(let value), .cancelling(let value), .failed(let value, _): return value }
    }
    var active: Bool {
        switch self { case .waiting, .cancelling: return true; case .idle, .failed: return false }
    }
    var canCancel: Bool { if case .waiting = self { return true }; return false }
}
