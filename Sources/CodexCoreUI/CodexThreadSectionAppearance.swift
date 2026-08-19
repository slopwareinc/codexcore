import SwiftUI

public enum CodexThreadSectionAppearanceStyle {
    public static let iconOptions = ["folder", "star", "bookmark", "flag", "tag", "tray"]
    public static let colorOptions = ["blue", "purple", "green", "orange", "red", "pink", "yellow", "gray"]

    public static func systemImage(_ value: String?) -> String {
        switch value?.lowercased() {
        case "folder": "folder"
        case "star": "star.fill"
        case "bookmark": "bookmark.fill"
        case "flag": "flag.fill"
        case "tag": "tag.fill"
        case "tray": "tray.fill"
        default: "square.grid.2x2.fill"
        }
    }

    public static func color(_ value: String?, fallback: Color) -> Color {
        switch value?.lowercased() {
        case "blue": .blue
        case "purple": .purple
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "pink": .pink
        case "yellow": .yellow
        case "gray", "grey": .gray
        default: fallback
        }
    }
}
