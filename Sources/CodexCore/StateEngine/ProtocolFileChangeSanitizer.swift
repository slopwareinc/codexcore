import Foundation

/// Makes generated schema decoding tolerant of malformed file-change siblings.
///
/// This is a decode-only view. `ProtocolStateAdapter` still supplies the exact
/// raw item to canonical conversion, so placeholders never become canonical
/// truth and future wire fields remain lossless.
enum ProtocolFileChangeSanitizer {
    static func sanitize(_ value: CodexJSONValue) -> CodexJSONValue {
        switch value {
        case .array(let values):
            return .array(values.map(sanitize))
        case .dictionary(let object):
            if object.string(at: "type") == "fileChange" {
                // Canonical conversion reads only identity/type from the
                // generated value and receives the exact item as rawOverride.
                // An empty schema-only list therefore avoids decoding or
                // copying any potentially malformed or very large changes.
                var decodeOnly = object
                decodeOnly["changes"] = .array([])
                return .dictionary(decodeOnly)
            }
            return .dictionary(object.mapValues(sanitize))
        default:
            return value
        }
    }
}
