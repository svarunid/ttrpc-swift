import Testing
@testable import TTRPCCore

@Suite("StreamID Tests")
struct StreamIDTests {

    @Test("Odd IDs are client-initiated")
    func clientInitiated() {
        #expect(StreamID(1).isClientInitiated)
        #expect(StreamID(3).isClientInitiated)
        #expect(StreamID(255).isClientInitiated)
    }

    @Test("Even IDs are server-initiated")
    func serverInitiated() {
        #expect(StreamID(2).isServerInitiated)
        #expect(StreamID(4).isServerInitiated)
        #expect(StreamID(100).isServerInitiated)
    }

    @Test("Zero is neither client nor server initiated")
    func zeroID() {
        let zero = StreamID(0)
        #expect(!zero.isClientInitiated)
        #expect(!zero.isServerInitiated) // 0 is even but excluded by the && rawValue != 0 check
    }

    @Test("StreamID ordering")
    func ordering() {
        #expect(StreamID(1) < StreamID(3))
        #expect(StreamID(3) < StreamID(5))
        #expect(!(StreamID(5) < StreamID(3)))
    }
}

@Suite("StreamState Tests")
struct StreamStateTests {

    @Test("Initial state is open on both sides")
    func initialState() {
        let state = StreamState()
        #expect(!state.localClosed)
        #expect(!state.remoteClosed)
        #expect(!state.isFullyClosed)
    }

    @Test("Close local side")
    func closeLocal() {
        var state = StreamState()
        let didClose = state.closeLocal()
        #expect(didClose)
        #expect(state.localClosed)
        #expect(!state.remoteClosed)
        #expect(!state.isFullyClosed)
    }

    @Test("Close remote side")
    func closeRemote() {
        var state = StreamState()
        let didClose = state.closeRemote()
        #expect(didClose)
        #expect(!state.localClosed)
        #expect(state.remoteClosed)
        #expect(!state.isFullyClosed)
    }

    @Test("Fully closed when both sides close")
    func fullyClosed() {
        var state = StreamState()
        state.closeLocal()
        state.closeRemote()
        #expect(state.isFullyClosed)
    }

    @Test("Double close returns false")
    func doubleClose() {
        var state = StreamState()
        #expect(state.closeLocal() == true)
        #expect(state.closeLocal() == false)
        #expect(state.closeRemote() == true)
        #expect(state.closeRemote() == false)
    }
}
