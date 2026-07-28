import AppKit
import Foundation

/// FIFO cache for fully prepared AppKit transcript text.
///
/// Entry count is a secondary safety bound. The primary bound is a
/// conservative logical byte estimate that includes attributed runs, attribute
/// values, keys, dictionary entries, and order bookkeeping.
struct CodexPreparedTranscriptTextCache {
    private static let entryCapacity = 8_192

    private struct Entry {
        var text: CodexPreparedTranscriptText
        var estimatedRetainedByteCount: Int
        var nextKey: String?
    }

    private struct SaturatingByteEstimate {
        private(set) var total = 0

        mutating func add(_ value: Int) {
            guard value > 0, total != .max else { return }
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? .max : sum
        }

        mutating func addProduct(_ lhs: Int, _ rhs: Int) {
            guard lhs > 0, rhs > 0 else { return }
            let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            add(overflow ? .max : product)
        }
    }

    private var entriesByKey: [String: Entry] = [:]
    private var oldestKey: String?
    private var newestKey: String?
    private(set) var retainedByteCount = 0
    private let byteCapacity: Int

    init(byteCapacity: Int) {
        self.byteCapacity = max(0, byteCapacity)
    }

    var entryCount: Int {
        entriesByKey.count
    }

    func value(forKey key: String) -> CodexPreparedTranscriptText? {
        entriesByKey[key]?.text
    }

    mutating func insert(
        _ text: CodexPreparedTranscriptText,
        forKey key: String,
        sourceContent: String
    ) {
        guard entriesByKey[key] == nil,
              let estimatedBytes = Self.estimatedRetainedByteCount(
                  key: key,
                  sourceContent: sourceContent,
                  text: text
              ),
              estimatedBytes < .max,
              estimatedBytes <= byteCapacity
        else { return }

        while entriesByKey.count >= Self.entryCapacity {
            guard evictOldest() else { return }
        }
        let maximumExistingBytes = byteCapacity - estimatedBytes
        while retainedByteCount > maximumExistingBytes {
            guard evictOldest() else { return }
        }

        if let newestKey {
            entriesByKey[newestKey]?.nextKey = key
        } else {
            oldestKey = key
        }
        entriesByKey[key] = .init(
            text: text,
            estimatedRetainedByteCount: estimatedBytes,
            nextKey: nil
        )
        newestKey = key
        let (sum, overflow) = retainedByteCount.addingReportingOverflow(
            estimatedBytes
        )
        retainedByteCount = overflow ? .max : sum
    }

    private mutating func evictOldest() -> Bool {
        guard let key = oldestKey,
              let removed = entriesByKey.removeValue(forKey: key)
        else {
            oldestKey = nil
            newestKey = nil
            entriesByKey.removeAll(keepingCapacity: false)
            retainedByteCount = 0
            return false
        }
        oldestKey = removed.nextKey
        if removed.nextKey == nil {
            newestKey = nil
            entriesByKey.removeAll(keepingCapacity: false)
        }
        if removed.estimatedRetainedByteCount >= retainedByteCount {
            retainedByteCount = 0
        } else {
            retainedByteCount -= removed.estimatedRetainedByteCount
        }
        return true
    }

    private static func estimatedRetainedByteCount(
        key: String,
        sourceContent: String,
        text: CodexPreparedTranscriptText
    ) -> Int? {
        var estimate = SaturatingByteEstimate()
        estimate.add(sourceContent.utf8.count)
        let attributedString = text.attributedString
        estimate.addProduct(attributedString.length, 8)
        estimate.add(MemoryLayout<Entry>.stride)

        // Dictionary bucket/key, prepared-text heap roots, and linked FIFO
        // order. Charge key payload twice because the order link may retain
        // separate String storage.
        estimate.add(256)
        estimate.addProduct(key.utf8.count, 2)

        var supportsCaching = true
        if attributedString.length > 0 {
            attributedString.enumerateAttributes(
                in: NSRange(location: 0, length: attributedString.length)
            ) { attributes, _, stop in
                estimate.add(128)
                estimate.addProduct(attributes.count, 64)
                for (attributeKey, value) in attributes {
                    estimate.add(attributeKey.rawValue.utf8.count)
                    guard addAttributeValue(value, to: &estimate) else {
                        supportsCaching = false
                        stop.pointee = true
                        return
                    }
                }
            }
        }
        return supportsCaching ? estimate.total : nil
    }

    private static func addAttributeValue(
        _ value: Any,
        to estimate: inout SaturatingByteEstimate
    ) -> Bool {
        switch value {
        case is NSTextAttachment:
            return false
        case let url as URL:
            estimate.add(128)
            estimate.add(url.absoluteString.utf8.count)
        case let string as String:
            estimate.add(64)
            estimate.add(string.utf8.count)
        case let paragraphStyle as NSParagraphStyle:
            estimate.add(256)
            estimate.addProduct(paragraphStyle.tabStops.count, 128)
            for tabStop in paragraphStyle.tabStops {
                estimate.addProduct(tabStop.options.count, 64)
                for (optionKey, optionValue) in tabStop.options {
                    estimate.add(String(describing: optionKey).utf8.count)
                    guard addAttributeValue(optionValue, to: &estimate) else {
                        return false
                    }
                }
            }
            estimate.addProduct(paragraphStyle.textLists.count, 192)
            for textList in paragraphStyle.textLists {
                estimate.add(String(describing: textList.markerFormat).utf8.count)
            }
            estimate.addProduct(paragraphStyle.textBlocks.count, 384)
            for textBlock in paragraphStyle.textBlocks {
                estimate.add(textBlock is NSTextTableBlock ? 512 : 192)
            }
        case is NSFont, is NSColor:
            estimate.add(96)
        case is NSNumber, is NSValue:
            estimate.add(64)
        case is NSShadow:
            estimate.add(160)
        default:
            // Unknown attribute objects may retain arbitrary graphs. Render
            // them normally, but do not admit them to this cache.
            return false
        }
        return true
    }
}
