import Foundation
import Security

// A deliberately stable executable owns Keychain access across reader updates.
// Only a Square Mail parent signed by the pinned publisher can call it.
let certificate = "E9EDA8C68084E31D00019CB550FCB9294D486364"
let parent = [kSecGuestAttributePid as String: NSNumber(value: getppid())] as CFDictionary
var code: SecCode?, requirement: SecRequirement?
let rule = "identifier \"com.finwarman.squaremail\" and certificate leaf = H\"\(certificate)\""
guard SecCodeCopyGuestWithAttributes(nil, parent, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { exit(77) }
enum Operation: String, Decodable { case get, set, delete }
struct Request: Decodable { let operation: Operation; let service: String; let account: String; let data: Data? }
struct Reply: Encodable { let status: OSStatus; let data: Data? }
var input = Data()
while let chunk = try FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
    input.append(chunk); guard input.count <= 131072 else { exit(65) }
}
let request = try JSONDecoder().decode(Request.self, from: input)
guard request.account.utf8.count <= 512,
      request.service == "com.finwarman.squaremail.oauth" || request.service.hasPrefix("dev.f1nb0.test.") else { exit(65) }
if request.service.hasPrefix("dev.f1nb0.test.") { SecKeychainSetUserInteractionAllowed(false) }
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: request.service, kSecAttrAccount as String: request.account]
var status: OSStatus = errSecParam
var data: Data?
switch request.operation {
case .get:
    var get = query; get[kSecReturnData as String] = true; get[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; status = SecItemCopyMatching(get as CFDictionary, &result); data = result as? Data
case .set:
    if let value = request.data, value.count <= 65536 {
        status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound { var add = query; add[kSecValueData as String] = value; status = SecItemAdd(add as CFDictionary, nil) }
    }
case .delete: status = SecItemDelete(query as CFDictionary)
}
try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(Reply(status: status, data: data)))
