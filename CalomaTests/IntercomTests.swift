import CryptoKit
import Foundation
import Testing
@testable import Caloma

/// The intercom's wire format and call flow, without a network or a camera.
struct IntercomFrameTests {
    @Test func messagesSurviveTheWire() throws {
        let call = UUID()
        let messages: [IntercomMessage] = [
            .hello(device: UUID(), name: "Kitchen Board"),
            .ring(call: call, from: UUID(), name: "Dad", video: true, group: [UUID(), UUID()]),
            .accept(call: call, video: false),
            .decline(call: call, reason: .busy),
            .hangUp(call: call),
            .offer(call: call, sdp: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"),
            .answer(call: call, sdp: "v=0"),
            .candidate(call: call, sdp: "candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host", mid: "0", index: 0),
            .candidate(call: call, sdp: "candidate:2", mid: nil, index: 1),
            .camera(call: call, on: true),
            .find(name: "Playroom"),
        ]
        for message in messages {
            let frame = try IntercomFrame.encode(message)
            let length = try #require(IntercomFrame.length(fromHeader: frame.prefix(4)))
            #expect(length == frame.count - 4)
            #expect(try IntercomFrame.decode(frame.dropFirst(4)) == message)
        }
    }

    @Test func oversizedOrEmptyFramesAreRefused() {
        #expect(IntercomFrame.length(fromHeader: Data([0, 0, 0, 0])) == nil)
        #expect(IntercomFrame.length(fromHeader: Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(IntercomFrame.length(fromHeader: Data([0, 0, 1])) == nil)
        #expect(IntercomFrame.length(fromHeader: Data([0, 0, 1, 0])) == 256)
    }

    @Test func everyDeviceDerivesTheSameConnectionKey() {
        let key = SymmetricKey(size: .bits256)
        let copy = SymmetricKey(data: key.withUnsafeBytes { Data($0) })
        #expect(HouseholdKey.connectionKey(from: key) == HouseholdKey.connectionKey(from: copy))
        #expect(HouseholdKey.connectionKey(from: key).count == 32)
        #expect(HouseholdKey.connectionKey(from: key) != HouseholdKey.connectionKey(from: SymmetricKey(size: .bits256)))
        #expect(HouseholdKey.fingerprint(of: key).count == 6)
    }
}

struct CallStateTests {
    let me = UUID()
    let kitchen = UUID()
    let playroom = UUID()
    let call = UUID()

    private func dialing(_ targets: [UUID: String], video: Bool = true) -> (CallState, [CallEffect]) {
        var state = CallState()
        let effects = state.apply(.dial(call: call, to: targets, video: video, me: me, myName: "Dad"))
        return (state, effects)
    }

    @Test func callingOneBoardRingsIt() {
        let (state, effects) = dialing([kitchen: "Kitchen Board"])
        #expect(state.phase == .calling)
        #expect(state.ringingPeers == [kitchen])
        #expect(effects.contains(.startMedia(video: true)))
        #expect(effects.contains(.send(.ring(call: call, from: me, name: "Dad", video: true, group: []), to: kitchen)))
        #expect(effects.contains(.scheduleTimeout(call: call)))
    }

    @Test func answeringConnectsAndTheCallerOffers() {
        var (caller, _) = dialing([kitchen: "Kitchen Board"])
        var board = CallState()
        let rang = board.apply(.received(.ring(call: call, from: me, name: "Dad", video: true, group: []), from: me))
        #expect(board.phase == .ringing)
        #expect(board.offeredVideo)
        #expect(rang.contains(.ring(true)))

        let answered = board.apply(.answer(video: false))
        #expect(board.phase == .live)
        #expect(answered.contains(.ring(false)))
        #expect(answered.contains(.send(.accept(call: call, video: false), to: me)))
        #expect(answered.contains(.connect(me, offer: false)))

        let accepted = caller.apply(.received(.accept(call: call, video: false), from: kitchen))
        #expect(caller.phase == .live)
        #expect(caller.peers == [kitchen])
        #expect(accepted == [.connect(kitchen, offer: true)])

        // Setup flows to WebRTC only for devices in the call.
        let offer = IntercomMessage.offer(call: call, sdp: "v=0")
        #expect(board.apply(.received(offer, from: me)) == [.media(offer, from: me)])
        #expect(board.apply(.received(offer, from: playroom)).isEmpty)
    }

    @Test func aBusyBoardSaysSo() {
        var board = CallState()
        _ = board.apply(.received(.ring(call: call, from: me, name: "Dad", video: true, group: []), from: me))
        let other = UUID()
        let effects = board.apply(.received(.ring(call: other, from: playroom, name: "Playroom", video: false, group: []), from: playroom))
        #expect(effects == [.send(.decline(call: other, reason: .busy), to: playroom)])
        #expect(board.call == call)
    }

    @Test func declineEndsACallToOneBoard() {
        var (caller, _) = dialing([kitchen: "Kitchen Board"])
        let effects = caller.apply(.received(.decline(call: call, reason: .declined), from: kitchen))
        #expect(caller.phase == .ended("Kitchen Board · Declined"))
        #expect(effects.contains(.stopMedia))
        #expect(effects.contains(.scheduleClear))
        _ = caller.apply(.cleared)
        #expect(caller.phase == .idle)
    }

    @Test func callingAllBoardsKeepsRingingTheRest() {
        let (start, effects) = dialing([kitchen: "Kitchen Board", playroom: "Playroom"])
        var caller = start
        #expect(effects.filter { if case .send(.ring, _) = $0 { true } else { false } }.count == 2)
        _ = caller.apply(.received(.accept(call: call, video: true), from: kitchen))
        #expect(caller.phase == .live)
        #expect(caller.ringingPeers == [playroom])
        // Nobody else answers: the ring stops, the call goes on.
        let timedOut = caller.apply(.timedOut(call: call))
        #expect(timedOut == [.send(.hangUp(call: call), to: playroom)])
        #expect(caller.phase == .live)
        // The last board leaving ends it.
        let left = caller.apply(.received(.hangUp(call: call), from: kitchen))
        #expect(left.contains(.disconnect(kitchen)))
        #expect(caller.phase == .ended("Call ended"))
    }

    @Test func nobodyAnsweringIsMissedOnTheBoard() {
        var board = CallState()
        _ = board.apply(.received(.ring(call: call, from: me, name: "Dad", video: true, group: []), from: me))
        let effects = board.apply(.timedOut(call: call))
        #expect(board.phase == .idle)
        #expect(effects.contains(.ring(false)))
        #expect(effects.contains(.missed(from: me, name: "Dad")))
        #expect(effects.contains(.send(.decline(call: call, reason: .noAnswer), to: me)))
    }

    @Test func theCallerGivingUpIsAMissedCall() {
        var board = CallState()
        _ = board.apply(.received(.ring(call: call, from: me, name: "Dad", video: false, group: []), from: me))
        let effects = board.apply(.received(.hangUp(call: call), from: me))
        #expect(board.phase == .idle)
        #expect(effects == [.ring(false), .missed(from: me, name: "Dad")])
    }

    @Test func hangingUpTellsEveryone() {
        var (caller, _) = dialing([kitchen: "Kitchen Board", playroom: "Playroom"])
        _ = caller.apply(.received(.accept(call: call, video: true), from: kitchen))
        let effects = caller.apply(.hangUp)
        #expect(caller.phase == .idle)
        #expect(effects.contains(.send(.hangUp(call: call), to: kitchen)))
        #expect(effects.contains(.send(.hangUp(call: call), to: playroom)))
        #expect(effects.contains(.disconnect(kitchen)))
        #expect(effects.contains(.stopMedia))
    }

    @Test func losingTheCallerEndsTheCallOnTheBoard() {
        var board = CallState()
        _ = board.apply(.received(.ring(call: call, from: me, name: "Dad", video: true, group: []), from: me))
        _ = board.apply(.answer(video: true))
        let effects = board.apply(.lost(me))
        #expect(effects.contains(.disconnect(me)))
        #expect(effects.contains(.stopMedia))
        #expect(board.phase == .ended("Call ended"))
    }

    @Test func anUnreachableBoardEndsTheCall() {
        var (caller, _) = dialing([kitchen: "Kitchen Board"])
        _ = caller.apply(.lost(kitchen))
        #expect(caller.phase == .ended("Couldn't reach Kitchen Board"))
    }

    @Test func aLateAnswerIsToldTheCallIsOver() {
        var (caller, _) = dialing([kitchen: "Kitchen Board"])
        _ = caller.apply(.timedOut(call: call))
        let effects = caller.apply(.received(.accept(call: call, video: true), from: kitchen))
        #expect(effects == [.send(.hangUp(call: call), to: kitchen)])
    }
}
