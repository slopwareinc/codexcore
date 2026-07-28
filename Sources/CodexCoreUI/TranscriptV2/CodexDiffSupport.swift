import Foundation

struct CodexStableFingerprint: Sendable {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combineRawByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }

    mutating func finishRawField() { combineSeparator() }

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combineRawByte(byte)
        }
        combineSeparator()
    }

    mutating func combine(
        _ string: String,
        checkpoint: () throws -> Void
    ) rethrows {
        var bytesUntilCheckpoint = 64 * 1_024
        for byte in string.utf8 {
            combineRawByte(byte)
            bytesUntilCheckpoint -= 1
            if bytesUntilCheckpoint == 0 {
                try checkpoint()
                bytesUntilCheckpoint = 64 * 1_024
            }
        }
        combineSeparator()
    }

    mutating func combine(_ number: UInt64) {
        var littleEndian = number.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            for byte in bytes {
                combineRawByte(byte)
            }
        }
        combineSeparator()
    }

    private mutating func combineSeparator() {
        value ^= 0xFF
        value &*= 1_099_511_628_211
    }
}

extension CodexFileChangeKindV2 {
    var diffKind: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .unknown(let value): value
        }
    }

    var stableValue: String {
        switch self {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .unknown(let value): "unknown:\(value)"
        }
    }

    static func fromDiffKind(_ value: String) -> Self {
        switch value {
        case "added": .added
        case "modified": .modified
        case "deleted": .deleted
        case "renamed": .renamed
        default: .unknown(value)
        }
    }
}
