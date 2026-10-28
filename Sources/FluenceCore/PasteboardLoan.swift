import AppKit

/// What a pasteboard held, saved so it can be given back type for type (FLU-120).
@MainActor
public struct PasteboardSnapshot {
    public struct Entry: Equatable {
        public let type: NSPasteboard.PasteboardType
        public let data: Data
    }

    /// Every item's types in the order its owner gave them (the first is the richest), with
    /// their bytes. Reading a promised type now makes its owner provide it.
    public let items: [[Entry]]
    /// Types announced but never provided (a file promise, an owner gone): they cannot be
    /// written back. A count, never what they held.
    public let unreadableTypes: Int

    public init(of pasteboard: NSPasteboard) {
        var lost = 0
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    lost += 1
                    return nil
                }
                return Entry(type: type, data: data)
            }
        }
        unreadableTypes = lost
    }

    /// Puts the items back; an empty snapshot leaves the pasteboard empty.
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        // Items read from a pasteboard die with the clear, so each one is rebuilt.
        let rebuilt = items.filter { !$0.isEmpty }.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !rebuilt.isEmpty { pasteboard.writeObjects(rebuilt) }
    }
}

/// The paste route lends the pasteboard to a dictation for one ⌘V, then gives the user's own
/// contents back (FLU-120: a dictation never changes the clipboard). The app passes
/// `NSPasteboard.general`; the tests pass private named pasteboards.
@MainActor
public struct PasteboardLoan {
    /// Markers from nspasteboard.org that clipboard managers (Maccy, Paste, Raycast, Alfred…)
    /// honour: transient and concealed items stay out of their history.
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// What the user had before the dictation.
    public let snapshot: PasteboardSnapshot
    /// The pasteboard's `changeCount` right after the dictation was written.
    public let generation: Int
    private let text: String

    /// Writes `text` over what `pasteboard` holds — transient, concealed, this Mac only — and
    /// saves that first. While `earlier` is still out the pasteboard holds the previous
    /// dictation, not the user's contents: its snapshot is carried over instead.
    public init(lending text: String, on pasteboard: NSPasteboard, source: String?, after earlier: PasteboardLoan? = nil) {
        if let earlier, earlier.isOut(on: pasteboard) {
            snapshot = earlier.snapshot
        } else {
            snapshot = PasteboardSnapshot(of: pasteboard)
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        if let source { item.setString(source, forType: Self.sourceType) }
        // `.currentHostOnly` keeps it out of Universal Clipboard, which would otherwise hand
        // the dictation to every device signed in to the same account.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects([item])
        generation = pasteboard.changeCount
        self.text = text
    }

    /// Whether the pasteboard still holds the dictation. Reading it — the paste itself — does
    /// not move `changeCount`; a write does. A write of the very same text (a clipboard
    /// manager re-posting what it saw) still counts as ours.
    public func isOut(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == generation || pasteboard.string(forType: .string) == text
    }

    /// Gives the user's contents back, unless someone else wrote meanwhile (the user copied
    /// something, a password manager filled): that newer content wins.
    @discardableResult
    public func giveBack(to pasteboard: NSPasteboard) -> Bool {
        guard isOut(on: pasteboard) else { return false }
        snapshot.restore(to: pasteboard)
        return true
    }
}
