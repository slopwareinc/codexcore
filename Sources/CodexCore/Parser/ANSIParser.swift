import Foundation

// MARK: - ANSI semantic color attributes (SGR codes 30–37, 39, 90–97)

public enum ANSIForegroundColor: Equatable, Sendable {
    case `default`
    case black
    case red
    case green
    case yellow
    case blue
    case purple
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightPurple
    case brightCyan
    case brightWhite
}

public enum ANSIBackgroundColor: Equatable, Sendable {
    case `default`
    case black
    case red
    case green
    case yellow
    case blue
    case purple
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightPurple
    case brightCyan
    case brightWhite
}

// MARK: - ANSI Style Definition

public struct ANSIStyle: Equatable, Sendable {
    public var foregroundColor: ANSIForegroundColor = .default
    public var backgroundColor: ANSIBackgroundColor? = nil
    public var isBold: Bool = false
    public var isUnderlined: Bool = false

    public init() {}

    public mutating func reset() {
        self.foregroundColor = .default
        self.backgroundColor = nil
        self.isBold = false
        self.isUnderlined = false
    }
}

// MARK: - ANSI Segment

public struct ANSISegment: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let style: ANSIStyle

    public init(text: String, style: ANSIStyle) {
        self.text = text
        self.style = style
    }
}

// MARK: - ANSI Escape Parser

public final class ANSIParser: Sendable {

    public init() {}

    /// Parses a string containing raw ANSI escape sequences and ignores OSC blocks, returning styled segments.
    public func parse(_ input: String) -> [ANSISegment] {
        var segments: [ANSISegment] = []
        var currentStyle = ANSIStyle()
        var currentText = ""

        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Check for Escape character: '\u{001B}' or '\u{009B}'
            if c == "\u{001B}" {
                // Flush existing segment first
                if !currentText.isEmpty {
                    segments.append(ANSISegment(text: currentText, style: currentStyle))
                    currentText = ""
                }

                i += 1
                guard i < chars.count else { break }
                let nextC = chars[i]

                if nextC == "[" { // CSI Sequence
                    i += 1
                    var paramsString = ""
                    while i < chars.count {
                        let codeC = chars[i]
                        if codeC.isLetter {
                            // SGR command: 'm' represents color/style modifiers
                            if codeC == "m" {
                                applySGR(paramsString, to: &currentStyle)
                            }
                            i += 1
                            break
                        } else {
                            paramsString.append(codeC)
                            i += 1
                        }
                    }
                } else if nextC == "]" { // OSC Sequence (e.g. Hyperlinks)
                    // Consume everything until BEL (\u{0007}) or ST (ESC \)
                    i += 1
                    while i < chars.count {
                        let oscC = chars[i]
                        if oscC == "\u{0007}" { // BEL
                            i += 1
                            break
                        } else if oscC == "\u{001B}" && i + 1 < chars.count && chars[i + 1] == "\\" { // ST
                            i += 2
                            break
                        } else {
                            i += 1
                        }
                    }
                } else {
                    // Unhandled escape character, consume next
                    i += 1
                }
            } else {
                currentText.append(c)
                i += 1
            }
        }

        if !currentText.isEmpty {
            segments.append(ANSISegment(text: currentText, style: currentStyle))
        }

        return segments
    }

    // MARK: - SGR Parser Helper

    private func applySGR(_ params: String, to style: inout ANSIStyle) {
        let codes = params.split(separator: ";").compactMap { Int($0) }
        let codesList = codes.isEmpty ? [0] : codes

        for code in codesList {
            switch code {
            case 0:
                style.reset()
            case 1:
                style.isBold = true
            case 4:
                style.isUnderlined = true
            case 22:
                style.isBold = false
            case 24:
                style.isUnderlined = false

            // Foreground colors
            case 30: style.foregroundColor = .black
            case 31: style.foregroundColor = .red
            case 32: style.foregroundColor = .green
            case 33: style.foregroundColor = .yellow
            case 34: style.foregroundColor = .blue
            case 35: style.foregroundColor = .purple
            case 36: style.foregroundColor = .cyan
            case 37: style.foregroundColor = .white
            case 39: style.foregroundColor = .default

            // Bright foreground colors
            case 90: style.foregroundColor = .brightBlack
            case 91: style.foregroundColor = .brightRed
            case 92: style.foregroundColor = .brightGreen
            case 93: style.foregroundColor = .brightYellow
            case 94: style.foregroundColor = .brightBlue
            case 95: style.foregroundColor = .brightPurple
            case 96: style.foregroundColor = .brightCyan
            case 97: style.foregroundColor = .brightWhite

            // Background colors
            case 40: style.backgroundColor = .black
            case 41: style.backgroundColor = .red
            case 42: style.backgroundColor = .green
            case 43: style.backgroundColor = .yellow
            case 44: style.backgroundColor = .blue
            case 45: style.backgroundColor = .purple
            case 46: style.backgroundColor = .cyan
            case 47: style.backgroundColor = .white
            case 49: style.backgroundColor = nil

            // Bright background colors
            case 100: style.backgroundColor = .brightBlack
            case 101: style.backgroundColor = .brightRed
            case 102: style.backgroundColor = .brightGreen
            case 103: style.backgroundColor = .brightYellow
            case 104: style.backgroundColor = .brightBlue
            case 105: style.backgroundColor = .brightPurple
            case 106: style.backgroundColor = .brightCyan
            case 107: style.backgroundColor = .brightWhite

            default:
                break
            }
        }
    }
}
