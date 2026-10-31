import AppKit

/// One paste owns its text, read receipt and timeout. A delayed read or timeout from
/// an earlier paste must never supply text or finish the receipt of a later paste.
@MainActor
public final class PasteboardPromise: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private var finished = false
    private var firstRead: UInt64?
    private var waiters: [CheckedContinuation<UInt64?, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    public private(set) var lastRead: UInt64 = 0

    public init(text: String) { self.text = text }

    /// Advertise a promise without resolving it until the target requests the text.
    @discardableResult
    public func write(to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        for marker in PasteboardInsertion.markerTypes {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// A read is a clipboard receipt, not proof that the target inserted the text.
    /// Reads before this call are retained; a late read after a timeout stays a failure.
    public func waitForRead(timeout: Duration = .milliseconds(1500)) async -> UInt64? {
        if finished { return firstRead }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if timeoutTask == nil {
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(at: nil)
                }
            }
        }
    }

    private func finish(at time: UInt64?) {
        guard !finished else { return }
        finished = true
        firstRead = time
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: time) }
    }

    public nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                                      provideDataForType type: NSPasteboard.PasteboardType) {
        let now = monotonicNanos()
        let provide = { @MainActor in
            item.setString(self.text, forType: .string)
            self.lastRead = now
            self.finish(at: now)
        }
        if Thread.isMainThread { MainActor.assumeIsolated { provide() } }
        else { DispatchQueue.main.sync { provide() } }
    }

    public nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
