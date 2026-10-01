import Testing
@testable import SapthamCore

struct SpeechGateTests {
    /// Feeds `seconds` at `rms` in 0.1 s blocks; returns whether it ended open.
    @discardableResult
    private func feed(_ gate: inout SpeechGate, rms: Float, seconds: Double) -> Bool {
        var open = gate.isOpen
        for _ in 0..<Int((seconds * 10).rounded()) { open = gate.add(rms: rms, seconds: 0.1) }
        return open
    }

    @Test func closesAfterAQuietSpell() {
        var gate = SpeechGate()
        let open1 = feed(&gate, rms: 0.002, seconds: 1.5)          // still holding open
        #expect(open1)
        let open2 = feed(&gate, rms: 0.002, seconds: 1.0)         // 2.5 s of quiet
        #expect(!open2)
    }

    @Test func opensAtOnceForAVoiceOverARoom() {
        var gate = SpeechGate()
        feed(&gate, rms: 0.003, seconds: 5)                     // quiet room, about -50 dBFS
        #expect(!gate.isOpen)
        let open3 = gate.add(rms: 0.03, seconds: 0.1)              // +20 dB: someone speaks
        #expect(open3)
    }

    @Test func staysOpenThroughPausesBetweenWords() {
        var gate = SpeechGate()
        feed(&gate, rms: 0.003, seconds: 5)
        for _ in 0..<5 {
            let open4 = feed(&gate, rms: 0.05, seconds: 0.4)
            #expect(open4)
            let open5 = feed(&gate, rms: 0.003, seconds: 0.6)       // a pause shorter than holdOpen
            #expect(open5)
        }
    }

    @Test func aSteadyNoiseBecomesBackground() {
        var gate = SpeechGate()
        feed(&gate, rms: 0.003, seconds: 3)
        // A fan switches on, +15 dB, and stays on: after a while it is the room.
        feed(&gate, rms: 0.017, seconds: 40)
        #expect(!gate.isOpen)
        let open6 = gate.add(rms: 0.2, seconds: 0.1)               // a voice over the fan still opens it
        #expect(open6)
    }

    @Test func digitalSilenceNeverOpens() {
        var gate = SpeechGate()
        feed(&gate, rms: 0, seconds: 3)
        let open7 = feed(&gate, rms: 0.0005, seconds: 1)           // -66 dBFS: below the floor
        #expect(!open7)
    }
}
