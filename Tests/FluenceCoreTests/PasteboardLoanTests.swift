import AppKit
import Foundation
import Testing

@testable import FluenceCore

/// FLU-120: the paste route borrows the pasteboard for one ⌘V and gives the user's contents
/// back byte for byte. Private named pasteboards only — never the user's clipboard.
@MainActor
struct PasteboardLoanTests {
    private static let custom = NSPasteboard.PasteboardType("io.github.clementvnrd.fluence.test.custom")

    private func withPrivatePasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard(name: .init("fluence.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    /// What the user had: two items, several types each, in a deliberate order.
    private func fillWithUserContent(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setData(Data("<b>un</b>".utf8), forType: .html)
        first.setData(Data([0x00, 0xFF, 0x10, 0x80]), forType: Self.custom)
        first.setData(Data("{\\rtf1 un}".utf8), forType: .rtf)
        first.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        first.setString("un", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data([0x01, 0x02, 0x03]), forType: .tiff)
        second.setString("deux", forType: .string)
        pasteboard.writeObjects([first, second])
    }

    /// Each item's types, in order, with their bytes.
    private func read(_ pasteboard: NSPasteboard) -> [[String]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.map { type in
                type.rawValue + "=" + (item.data(forType: type)?.base64EncodedString() ?? "nil")
            }
        }
    }

    @Test func everyItemAndTypeComesBackByteForByteInOrder() {
        withPrivatePasteboard { pasteboard in
            fillWithUserContent(pasteboard)
            let before = read(pasteboard)
            #expect(before.count == 2)

            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: "test")
            #expect(pasteboard.string(forType: .string) == "dictée")
            #expect(pasteboard.data(forType: PasteboardLoan.transientType) != nil)
            #expect(pasteboard.data(forType: PasteboardLoan.concealedType) != nil)

            #expect(loan.giveBack(to: pasteboard))
            #expect(read(pasteboard) == before)
            #expect(loan.snapshot.unreadableTypes == 0)
        }
    }

    @Test func readingThePasteboardDoesNotMoveChangeCount() {
        withPrivatePasteboard { pasteboard in
            fillWithUserContent(pasteboard)
            let before = read(pasteboard)
            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: nil)
            // What a target app does on ⌘V.
            _ = pasteboard.string(forType: .string)
            _ = pasteboard.pasteboardItems?.map { $0.types }
            #expect(pasteboard.changeCount == loan.generation)
            #expect(loan.giveBack(to: pasteboard))
            #expect(read(pasteboard) == before)
        }
    }

    @Test func anotherWriterWinsAndIsLeftAlone() {
        withPrivatePasteboard { pasteboard in
            fillWithUserContent(pasteboard)
            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: nil)
            pasteboard.clearContents()
            pasteboard.setString("copié entre-temps", forType: .string)
            #expect(!loan.isOut(on: pasteboard))
            #expect(!loan.giveBack(to: pasteboard))
            #expect(pasteboard.string(forType: .string) == "copié entre-temps")
        }
    }

    @Test func aRewriteOfTheDictationItselfStillGivesTheUsersContentBack() {
        withPrivatePasteboard { pasteboard in
            fillWithUserContent(pasteboard)
            let before = read(pasteboard)
            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: nil)
            // A clipboard manager re-posting what it saw: changeCount moves, the content is ours.
            pasteboard.clearContents()
            pasteboard.setString("dictée", forType: .string)
            #expect(pasteboard.changeCount != loan.generation)
            #expect(loan.giveBack(to: pasteboard))
            #expect(read(pasteboard) == before)
        }
    }

    @Test func anEmptyPasteboardStaysEmpty() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: nil)
            #expect(loan.giveBack(to: pasteboard))
            #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func aSecondDictationBeforeTheFirstIsGivenBackKeepsTheUsersContent() {
        withPrivatePasteboard { pasteboard in
            fillWithUserContent(pasteboard)
            let before = read(pasteboard)
            let first = PasteboardLoan(lending: "première", on: pasteboard, source: nil)
            let second = PasteboardLoan(lending: "seconde", on: pasteboard, source: nil, after: first)
            #expect(second.giveBack(to: pasteboard))
            #expect(read(pasteboard) == before)
        }
    }

    @Test func aPromiseNobodyKeepsIsCountedAndTheRestComesBack() {
        withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("texte", forType: .string)
            #expect(item.setDataProvider(BrokenPromise(), forTypes: [Self.custom]))
            pasteboard.writeObjects([item])

            let loan = PasteboardLoan(lending: "dictée", on: pasteboard, source: nil)
            #expect(loan.snapshot.unreadableTypes == 1)
            #expect(loan.giveBack(to: pasteboard))
            #expect(pasteboard.string(forType: .string) == "texte")
        }
    }
}

/// Announces a type and never provides it.
private final class BrokenPromise: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}
