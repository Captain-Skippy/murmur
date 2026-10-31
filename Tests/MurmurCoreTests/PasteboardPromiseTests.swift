import AppKit
import Testing
@testable import MurmurCore

@Suite @MainActor struct PasteboardPromiseTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("murmur-promise-test-\(UUID())"))
    }

    @Test func readBeforeWaitingIsRetained() async {
        let pb = board()
        defer { pb.releaseGlobally() }
        let promise = PasteboardPromise(text: "first")
        promise.write(to: pb)
        #expect(pb.string(forType: .string) == "first")
        #expect(await promise.waitForRead() != nil)
        #expect(promise.lastRead > 0)
    }

    @Test func earlierTimeoutCannotFinishLaterPaste() async throws {
        let oldBoard = board(), newBoard = board()
        defer { oldBoard.releaseGlobally(); newBoard.releaseGlobally() }
        let old = PasteboardPromise(text: "old"), next = PasteboardPromise(text: "next")
        old.write(to: oldBoard)
        let oldReceipt = Task { await old.waitForRead(timeout: .milliseconds(30)) }
        await Task.yield()
        #expect(oldBoard.string(forType: .string) == "old")
        #expect(await oldReceipt.value != nil)
        next.write(to: newBoard)
        let nextReceipt = Task { await next.waitForRead(timeout: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(newBoard.string(forType: .string) == "next")
        #expect(await nextReceipt.value != nil)
    }

    @Test func lateOldCallbackKeepsItsTextAndReceipt() async {
        let oldBoard = board(), newBoard = board()
        defer { oldBoard.releaseGlobally(); newBoard.releaseGlobally() }
        let old = PasteboardPromise(text: "old"), next = PasteboardPromise(text: "next")
        old.write(to: oldBoard)
        #expect(await old.waitForRead(timeout: .milliseconds(10)) == nil)
        next.write(to: newBoard)
        // A delayed native provider callback must retain its original text and result.
        #expect(oldBoard.string(forType: .string) == "old")
        #expect(await old.waitForRead() == nil)
        #expect(newBoard.string(forType: .string) == "next")
        #expect(await next.waitForRead() != nil)
    }

    @Test func promisedPasteRestoresRichClipboardButPreservesNewCopy() async {
        let pb = board()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data("<b>original</b>".utf8), forType: .html)
        pb.writeObjects([item])
        let snapshot = PasteboardSnapshot.capture(pb)
        let promise = PasteboardPromise(text: "dictated")
        let ours = promise.write(to: pb)
        #expect(pb.pasteboardItems!.first!.types.contains(NSPasteboard.PasteboardType(PasteboardInsertion.markerTypes[0])))
        #expect(pb.string(forType: .string) == "dictated")
        #expect(await promise.waitForRead() != nil)
        #expect(PasteboardInsertion.restoreIfUnchanged(snapshot, ourChangeCount: ours, to: pb))
        #expect(pb.data(forType: .html) == Data("<b>original</b>".utf8))
        let next = PasteboardPromise(text: "next")
        let nextCount = next.write(to: pb)
        pb.clearContents()
        pb.setString("new user copy", forType: .string)
        #expect(!PasteboardInsertion.restoreIfUnchanged(snapshot, ourChangeCount: nextCount, to: pb))
        #expect(pb.string(forType: .string) == "new user copy")
    }
}
