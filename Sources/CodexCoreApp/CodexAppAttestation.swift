import DeviceCheck
import Foundation

actor CodexAppAttestation {
    static let shared = CodexAppAttestation()

    private static let codexBundleID = "com.openai.codex"
    private static let appSessionID = UUID().uuidString

    private var cachedToken: String?
    private var pendingTask: Task<String, Never>?

    func prepare() async {
        _ = await token()
    }

    func token() async -> String {
        if let cachedToken {
            return cachedToken
        }
        if let pendingTask {
            return await pendingTask.value
        }

        let task = Task {
            await Self.generateClientAttestation()
        }
        pendingTask = task
        let token = await task.value
        cachedToken = token
        pendingTask = nil
        return token
    }

    private static func generateClientAttestation() async -> String {
        let started = ContinuousClock.now
        let result = await generateDeviceToken()
        let latency = started.duration(to: .now)
        let latencyMilliseconds = Double(latency.components.seconds) * 1_000
            + Double(latency.components.attoseconds) / 1_000_000_000_000_000

        var entries: [(Data, Data)] = []
        if result.supported, let deviceToken = result.token {
            entries.append((CBOR.text("token"), CBOR.text(deviceToken.base64EncodedString())))
        } else {
            entries.append((CBOR.text("error_code"), CBOR.unsigned(result.supported ? 4 : 3)))
        }
        entries.append((CBOR.text("bundle_id"), CBOR.text(codexBundleID)))
        entries.append((CBOR.text("f"), CBOR.bytes(attestationSignals())))
        entries.append((CBOR.text("t"), CBOR.double(latencyMilliseconds)))

        return "v1.\(CBOR.map(entries).base64URLEncodedString())"
    }

    private static func generateDeviceToken() async -> (supported: Bool, token: Data?) {
        let device = DCDevice.current
        guard device.isSupported else {
            return (false, nil)
        }

        do {
            let token = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                device.generateToken { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(
                            throwing: error ?? CodexAppAttestationError.emptyDeviceToken
                        )
                    }
                }
            }
            return (true, token)
        } catch {
            return (true, nil)
        }
    }

    private static func attestationSignals() -> Data {
        let locale = String(Locale.current.identifier.prefix(64))
        let timezone = String(TimeZone.current.identifier.prefix(64))
        return CBOR.map([
            (CBOR.unsigned(0), CBOR.unsigned(1)),
            (CBOR.unsigned(1), CBOR.array([CBOR.text(locale)])),
            (CBOR.unsigned(2), CBOR.text(locale)),
            (CBOR.unsigned(3), CBOR.text(timezone)),
            (CBOR.unsigned(4), CBOR.unsigned(0)),
            (CBOR.unsigned(5), CBOR.unsigned(1)),
            (CBOR.unsigned(6), CBOR.text(String(appSessionID.prefix(128)))),
        ])
    }
}

private enum CodexAppAttestationError: Error {
    case emptyDeviceToken
}

private enum CBOR {
    static func unsigned(_ value: UInt64) -> Data {
        header(major: 0, value: value)
    }

    static func bytes(_ value: Data) -> Data {
        header(major: 2, value: UInt64(value.count)) + value
    }

    static func text(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return header(major: 3, value: UInt64(bytes.count)) + bytes
    }

    static func array(_ values: [Data]) -> Data {
        values.reduce(into: header(major: 4, value: UInt64(values.count))) {
            $0.append($1)
        }
    }

    static func map(_ entries: [(Data, Data)]) -> Data {
        entries.reduce(into: header(major: 5, value: UInt64(entries.count))) {
            $0.append($1.0)
            $0.append($1.1)
        }
    }

    static func double(_ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        var data = Data([0xfb])
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        return data
    }

    private static func header(major: UInt8, value: UInt64) -> Data {
        let prefix = major << 5
        switch value {
        case 0..<24:
            return Data([prefix | UInt8(value)])
        case 24...UInt64(UInt8.max):
            return Data([prefix | 24, UInt8(value)])
        case 0...UInt64(UInt16.max):
            var encoded = UInt16(value).bigEndian
            return Data([prefix | 25]) + withUnsafeBytes(of: &encoded) { Data($0) }
        case 0...UInt64(UInt32.max):
            var encoded = UInt32(value).bigEndian
            return Data([prefix | 26]) + withUnsafeBytes(of: &encoded) { Data($0) }
        default:
            var encoded = value.bigEndian
            return Data([prefix | 27]) + withUnsafeBytes(of: &encoded) { Data($0) }
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
