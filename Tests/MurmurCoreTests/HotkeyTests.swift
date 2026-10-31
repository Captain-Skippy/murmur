import Testing
@testable import MurmurCore

@Suite struct HotkeyTests {
    @Test func holdDictates() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.keyDown(ms: 0)) == [.start])
        #expect(m.isRecording)
        #expect(m.handle(.keyUp(ms: 1500)) == [.stopAndProcess])
        #expect(m.state == .idle)
    }

    @Test func singleTapDiscards() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        #expect(m.handle(.keyUp(ms: 100)) == [.cancel])
    }

    @Test func doubleTapStartsHandsFreeAndTapStops() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        _ = m.handle(.keyUp(ms: 90))
        #expect(m.handle(.keyDown(ms: 250)) == [.start])
        #expect(m.handle(.keyUp(ms: 330)) == [.enterHandsFree])
        #expect(m.state == .handsFree)
        #expect(m.handle(.otherKey(ms: 2000)) == [])   // typing during hands-free is fine
        #expect(m.handle(.keyDown(ms: 9000)) == [.stopAndProcess])
        #expect(m.handle(.keyUp(ms: 9080)) == [])
        #expect(m.state == .idle)
    }

    @Test func slowSecondTapIsNotDoubleTap() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        _ = m.handle(.keyUp(ms: 90))
        _ = m.handle(.keyDown(ms: 900))
        #expect(m.handle(.keyUp(ms: 980)) == [.cancel])
    }

    @Test func secondPressHeldLongIsNormalDictation() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        _ = m.handle(.keyUp(ms: 90))
        _ = m.handle(.keyDown(ms: 200))
        #expect(m.handle(.keyUp(ms: 3000)) == [.stopAndProcess])
    }

    @Test func chordCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        #expect(m.handle(.otherKey(ms: 50)) == [.cancel])
        #expect(m.handle(.keyUp(ms: 120)) == [])
        #expect(m.state == .idle)
    }

    @Test func laterKeysDoNotCancel() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        #expect(m.handle(.otherKey(ms: 1500)) == [])   // F11 mid-sentence
        #expect(m.handle(.keyUp(ms: 3000)) == [.stopAndProcess])
    }

    @Test func escapeCancelsHoldAndHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0))
        #expect(m.handle(.escape) == [.cancel])
        _ = m.handle(.keyUp(ms: 500))
        _ = m.handle(.keyDown(ms: 1000)); _ = m.handle(.keyUp(ms: 1050))
        _ = m.handle(.keyDown(ms: 1200)); _ = m.handle(.keyUp(ms: 1250))
        #expect(m.state == .handsFree)
        #expect(m.handle(.escape) == [.cancel])
        #expect(m.state == .idle)
    }

    @Test func keyPlusSpaceStartsHandsFree() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.keyDown(ms: 0)) == [.start])
        #expect(m.handle(.handsFreeKey(ms: 80)) == [.enterHandsFree])
        #expect(m.handle(.keyUp(ms: 150)) == [])          // releasing Fn keeps recording
        #expect(m.state == .handsFree)
        #expect(m.handle(.keyDown(ms: 8000)) == [.stopAndProcess])
        #expect(m.handle(.keyUp(ms: 8100)) == [])
        #expect(m.state == .idle)
    }

    @Test func tapAfterChordIsNotHalfOfDoubleTap() {
        var m = HotkeyStateMachine()
        _ = m.handle(.keyDown(ms: 0)); _ = m.handle(.keyUp(ms: 80))
        _ = m.handle(.otherKey(ms: 100))
        _ = m.handle(.keyDown(ms: 200))
        #expect(m.handle(.keyUp(ms: 260)) == [.cancel])
    }
}
