import CodexCore
import SwiftUI

/// Maps semantic ANSI attributes from `CodexCore` to SwiftUI presentation values.
public enum ANSITerminalStyle: Sendable {
    public static func foregroundColor(for color: ANSIForegroundColor) -> Color {
        switch color {
        case .default: .primary
        case .black: .black
        case .red: .red
        case .green: .green
        case .yellow: .yellow
        case .blue: .blue
        case .purple: .purple
        case .cyan: .cyan
        case .white: .white
        case .brightBlack: .gray
        case .brightRed: Color(red: 1.0, green: 0.3, blue: 0.3)
        case .brightGreen: Color(red: 0.3, green: 1.0, blue: 0.3)
        case .brightYellow: Color(red: 1.0, green: 1.0, blue: 0.3)
        case .brightBlue: Color(red: 0.3, green: 0.3, blue: 1.0)
        case .brightPurple: Color(red: 1.0, green: 0.3, blue: 1.0)
        case .brightCyan: Color(red: 0.3, green: 1.0, blue: 1.0)
        case .brightWhite: .white
        }
    }

    public static func backgroundColor(for color: ANSIBackgroundColor) -> Color {
        switch color {
        case .default: .clear
        case .black: .black
        case .red: .red
        case .green: .green
        case .yellow: .yellow
        case .blue: .blue
        case .purple: .purple
        case .cyan: .cyan
        case .white: .white
        case .brightBlack: .gray
        case .brightRed: Color(red: 1.0, green: 0.4, blue: 0.4)
        case .brightGreen: Color(red: 0.4, green: 1.0, blue: 0.4)
        case .brightYellow: Color(red: 1.0, green: 1.0, blue: 0.4)
        case .brightBlue: Color(red: 0.4, green: 0.4, blue: 1.0)
        case .brightPurple: Color(red: 1.0, green: 0.4, blue: 1.0)
        case .brightCyan: Color(red: 0.4, green: 1.0, blue: 1.0)
        case .brightWhite: .white
        }
    }

    /// Converts styled segments into a single native SwiftUI AttributedString.
    @available(macOS 12.0, iOS 15.0, *)
    public static func makeAttributedString(from segments: [ANSISegment]) -> Foundation.AttributedString {
        var result = Foundation.AttributedString()

        for segment in segments {
            var span = Foundation.AttributedString(segment.text)

            if segment.style.isBold {
                span.inlinePresentationIntent = .stronglyEmphasized
            }

            if segment.style.isUnderlined {
                span.underlineStyle = .single
            }

            if segment.style.foregroundColor != .default {
                span.foregroundColor = foregroundColor(for: segment.style.foregroundColor)
            }

            if let background = segment.style.backgroundColor {
                span.backgroundColor = backgroundColor(for: background)
            }

            result.append(span)
        }

        return result
    }
}
