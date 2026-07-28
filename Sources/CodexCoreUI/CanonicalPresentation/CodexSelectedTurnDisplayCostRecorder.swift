import CodexCore

struct CodexSelectedTurnDisplayCost: Sendable {
    var estimatedByteCount: Int
    var exceedsLimit: Bool
}
/// Selected-child-only upper bound recorded while one dirty turn is projected.
///
/// Projected strings either share source storage or are copied into a row,
/// bounded display preparation, and the transcript value. Charging source UTF-8
/// four times plus fixed value/node overhead conservatively covers those paths
/// without mirroring the transcript model or revisiting unchanged turns.
enum CodexSelectedTurnDisplayCostRecorder {
    private static let sourceUTF8Multiplier = 4
    private static let itemOverhead = 1_024
    private static let nodeOverhead = 64
    private static let maximumDepth = 128
    private static let maximumNodeCount = 131_072
    static func measure(
        projected: CodexTurnV2,
        items: [CanonicalItem],
        intents: [SubmissionIntent],
        stoppingAfter limit: Int,
        checkpoint: () throws -> Void
    ) rethrows -> CodexSelectedTurnDisplayCost {
        guard items.count <= maximumNodeCount,
              intents.count <= maximumNodeCount else {
            return .init(estimatedByteCount: max(0, limit), exceedsLimit: true)
        }
        var accumulator = Accumulator(limit: max(0, limit))
        accumulator.addProduct(items.count, itemOverhead)
        accumulator.addProduct(intents.count, itemOverhead)
        accumulator.addString(projected.id)
        if case .failed(let message) = projected.status {
            accumulator.addString(message)
        }
        for item in items {
            try checkpoint()
            accumulator.addString(item.key.itemID.rawValue)
            accumulator.addString(item.clientUserMessageID?.rawValue)
            try accumulator.add(item.payload, checkpoint: checkpoint)
            try accumulator.add(item.liveFields, checkpoint: checkpoint)
            try accumulator.add(item.liveOverlay, checkpoint: checkpoint)
            guard !accumulator.exceedsLimit else { break }
        }
        if !accumulator.exceedsLimit {
            for intent in intents {
                try checkpoint()
                accumulator.addString(intent.id.rawValue)
                accumulator.addString(intent.expectedTurnID?.rawValue)
                switch intent.state {
                case .failed(let message): accumulator.addString(message)
                case .indeterminate(let message): accumulator.addString(message)
                case .reconciled(let item): accumulator.addString(item.itemID.rawValue)
                case .pending: break
                }
                for value in intent.input {
                    try accumulator.add(value, checkpoint: checkpoint)
                    guard !accumulator.exceedsLimit else { break }
                }
                if accumulator.exceedsLimit { break }
            }
        }
        return .init(estimatedByteCount: accumulator.total,
                     exceedsLimit: accumulator.exceedsLimit)
    }
    private struct Accumulator {
        private(set) var total = 0
        private var nodeCount = 0
        private var exceededBounds = false
        let limit: Int

        var exceedsLimit: Bool {
            exceededBounds || total > limit
        }
        mutating func add(
            _ object: [String: CodexJSONValue],
            depth: Int = 0,
            checkpoint: () throws -> Void
        ) rethrows {
            guard !exceedsLimit else { return }
            guard object.count <= maximumNodeCount else { exceed(); return }
            addProduct(object.count, nodeOverhead)
            for (key, value) in object {
                try checkpoint()
                addString(key)
                try add(value, depth: depth + 1, checkpoint: checkpoint)
                guard !exceedsLimit else { return }
            }
        }
        mutating func add(
            _ value: CodexJSONValue,
            depth: Int = 0,
            checkpoint: () throws -> Void
        ) rethrows {
            try checkpoint()
            guard !exceedsLimit else { return }
            nodeCount += 1
            guard depth <= maximumDepth, nodeCount <= maximumNodeCount
            else { exceed(); return }
            addBytes(nodeOverhead)
            switch value {
            case .string(let string):
                addString(string)
            case .array(let values):
                guard values.count <= maximumNodeCount else { exceed(); return }
                addProduct(values.count, nodeOverhead)
                for value in values {
                    try add(value, depth: depth + 1, checkpoint: checkpoint)
                    guard !exceedsLimit else { return }
                }
            case .dictionary(let object):
                try add(object, depth: depth + 1, checkpoint: checkpoint)
            case .int, .double, .bool, .null:
                break
            }
        }
        mutating func add(
            _ overlay: ItemLiveOverlay,
            checkpoint: () throws -> Void
        ) rethrows {
            guard !exceedsLimit else { return }
            guard overlay.reasoningSummary.count <= maximumNodeCount,
                  overlay.reasoningContent.count <= maximumNodeCount,
                  overlay.terminalInteractions.count <= maximumNodeCount
            else { exceed(); return }
            try checkpoint()
            for buffer in [overlay.agentMessage, overlay.plan, overlay.commandOutput,
                           overlay.fileChangeOutput, overlay.mcpProgress] {
                add(buffer)
                if exceedsLimit { return }
            }
            for buffers in [overlay.reasoningSummary, overlay.reasoningContent] {
                for buffer in buffers.values {
                    try checkpoint()
                    add(buffer)
                    if exceedsLimit { return }
                }
            }
            addProduct(overlay.terminalInteractions.count, nodeOverhead)
            guard !exceedsLimit else { return }
            for interaction in overlay.terminalInteractions {
                try checkpoint()
                addString(interaction.processID)
                addString(interaction.stdin)
                if exceedsLimit { return }
            }
        }
        mutating func add(_ buffer: TextChunkBuffer) {
            guard !exceedsLimit else { return }
            addProduct(buffer.chunks.count, nodeOverhead)
            addProduct(buffer.utf8ByteCount, sourceUTF8Multiplier)
        }
        mutating func addString(_ value: String?) {
            guard !exceedsLimit, let value else { return }
            addBytes(32)
            addProduct(value.utf8.count, sourceUTF8Multiplier)
        }

        mutating func addProduct(_ lhs: Int, _ rhs: Int) {
            guard !exceedsLimit else { return }
            let (product, overflow) = max(0, lhs).multipliedReportingOverflow(
                by: max(0, rhs)
            )
            addBytes(overflow ? .max : product)
        }

        mutating func addBytes(_ value: Int) {
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            if overflow { exceed() } else { total = sum }
        }

        mutating func exceed() {
            exceededBounds = true
            total = limit == .max ? .max : limit + 1
        }
    }
}
