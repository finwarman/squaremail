import Foundation

// Decode display text once. This is not an HTML parser and never changes mail data.
public enum HeaderText {
    private static let inputLimit = 8192
    private static let entityLimit = 34
    private static let ampersand: UInt8 = 38
    private static let semicolon: UInt8 = 59
    private static let numberSign: UInt8 = 35
    private static let c1Range: ClosedRange<UInt32> = 0x80...0x9F
    private static let c1: [UInt32] = [0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178]
    public static func decode(_ source: String) -> String {
        if source.utf8.count <= inputLimit && !source.utf8.contains(ampersand) { return source }
        let bytes = Array(source.utf8.prefix(inputLimit))
        var result: [UInt8] = []; result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == ampersand else { result.append(bytes[index]); index += 1; continue }
            var end = index + 1
            while end < bytes.count && end - index <= entityLimit && isNameByte(bytes[end]) { end += 1 }
            guard end < bytes.count, bytes[end] == semicolon,
                  let value = value(String(decoding: bytes[(index + 1)..<end], as: UTF8.self)) else {
                result.append(bytes[index]); index += 1; continue
            }
            result.append(contentsOf: value.utf8); index = end + 1
        }
        return String(decoding: result, as: UTF8.self)
    }
    private static func isNameByte(_ byte: UInt8) -> Bool {
        byte == numberSign || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    private static func value(_ name: String) -> String? {
        guard name.first == "#" else { return HTMLNames.value(name) }
        let digits = name.dropFirst()
        let hex = digits.first == "x" || digits.first == "X"
        let number = hex ? digits.dropFirst() : digits
        guard !number.isEmpty, number.utf8.allSatisfy({ hex ? (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) : (48...57).contains($0) }),
              let code = UInt32(number, radix: hex ? 16 : 10), code != 0 else { return nil }
        let point = c1Range.contains(code) ? c1[Int(code - c1Range.lowerBound)] : code
        guard !c1Range.contains(point), let scalar = UnicodeScalar(point) else { return nil }
        return String(scalar)
    }
}
