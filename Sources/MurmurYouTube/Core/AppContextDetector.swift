import AppKit
import Foundation

/// Detects the user's active foreground application to adapt formatting and tone.
@MainActor
public enum AppContextDetector {

    public enum AppCategory: String, Sendable, CaseIterable {
        case developer
        case chat
        case formal
        case general

        public var displayName: String {
            switch self {
            case .developer: "Developer / Code"
            case .chat: "Chat & Messaging"
            case .formal: "Formal & Documents"
            case .general: "Standard"
            }
        }
    }

    public struct AppContext: Sendable {
        public let category: AppCategory
        public let appName: String
        public let bundleId: String?

        public var shouldSuppressTrailingPeriod: Bool {
            category == .developer
        }

        public var isChat: Bool {
            category == .chat
        }

        public var isFormal: Bool {
            category == .formal
        }

        public static let standard = AppContext(category: .general, appName: "Unknown", bundleId: nil)
    }

    /// Known bundle ID prefixes and identifiers for developer tools
    private static let developerAppIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",      // Windsurf
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.PyCharm",
        "com.jetbrains.WebStorm",
    ]

    /// Known bundle IDs for chat and messaging applications
    private static let chatAppIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.MobileSMS",          // Messages
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop",
        "com.microsoft.teams2",
        "com.microsoft.teams",
    ]

    /// Known bundle IDs for document and email apps
    private static let formalAppIdentifiers: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "com.apple.Notes",
        "notion.id",
    ]

    /// Resolves the current foreground application and its category.
    public static func currentContext() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .standard
        }

        let name = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier ?? ""

        let category: AppCategory
        if developerAppIdentifiers.contains(bundleId) || isDeveloperName(name) {
            category = .developer
        } else if chatAppIdentifiers.contains(bundleId) || isChatName(name) {
            category = .chat
        } else if formalAppIdentifiers.contains(bundleId) || isFormalName(name) {
            category = .formal
        } else {
            category = .general
        }

        return AppContext(category: category, appName: name, bundleId: bundleId.isEmpty ? nil : bundleId)
    }

    private static func isDeveloperName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("terminal") || lower.contains("iterm") || lower.contains("code") || lower.contains("cursor")
    }

    private static func isChatName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("slack") || lower.contains("discord") || lower.contains("messages") || lower.contains("whatsapp")
    }

    private static func isFormalName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("mail") || lower.contains("outlook") || lower.contains("pages")
    }
}
