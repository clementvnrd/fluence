import Foundation

/// The app's version as people see it ("0.1.0") and the build number macOS and the updater
/// compare (FLU-26).
///
/// The build number is derived from the version, never counted by hand: 0.1.0 → 100,
/// 0.1.1 → 101, 0.2.0 → 200, 1.0.0 → 10000. Every release is therefore above the one before
/// it, and above build 1, which the first, unversioned builds on Clement's Mac carry. Sparkle
/// installs an update only when its build number is higher than the running one.
public struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// "1.2.3" only: three numbers, minor and patch below 100 so the build number stays
    /// ordered (0.1.99 → 199 must stay below 0.2.0 → 200).
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3, numbers[0] < 1_000, numbers[1] < 100, numbers[2] < 100 else { return nil }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    /// `CFBundleVersion`.
    public var buildNumber: Int { major * 10_000 + minor * 100 + patch }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.buildNumber < rhs.buildNumber }
}

/// When an update may reach the user (FLU-26): never while they are dictating or a meeting is
/// being recorded or processed. A dialog would take the focus the dictation types into, and a
/// relaunch would end the recording.
public enum UpdatePolicy {
    public static func isBusy(dictating: Bool, meetingInProgress: Bool) -> Bool {
        dictating || meetingInProgress
    }

    /// "Fluence x.y.z est disponible": only when nothing is recording and the user is looking
    /// at Fluence — it never pops up over another app.
    public static func mayOffer(isBusy: Bool, appIsActive: Bool) -> Bool {
        !isBusy && appIsActive
    }

    /// Quitting into the new version: only once nothing is recording.
    public static func mayRelaunch(isBusy: Bool) -> Bool {
        !isBusy
    }
}

/// The release notes the feed carries as HTML, reduced to a few plain lines for the update
/// prompt.
public enum ReleaseNotesText {
    public static func summary(fromHTML html: String?, limit: Int = 320) -> String? {
        guard let html else { return nil }
        // Headings go: the prompt's own title already says « Fluence x.y.z est disponible ».
        var text = html.replacingOccurrences(of: "(?is)<h[1-6][^>]*>.*?</h[1-6]>", with: "\n", options: .regularExpression)
        // Line breaks where the HTML had blocks, so list items stay on their own lines.
        for tag in ["</p>", "</li>", "<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&#160;", " "), ("&lt;", "<"), ("&gt;", ">"),
                                    ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: "\n")
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        let end = cut.lastIndex(where: { $0 == "\n" || $0 == " " }) ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
