import Testing
@testable import SapthamCore

struct SpeechToneTests {
    /// `seconds` of audio at `rms`, in 0.1 s blocks.
    private func feed(_ tracker: LoudnessTracker, rms: Float, seconds: Double) {
        for _ in 0..<Int(seconds * 10) { tracker.add(rms: rms, seconds: 0.1) }
    }

    @Test func ordinarySpeechIsNormal() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.05, seconds: 10)
        #expect(tracker.tone(for: AudioSpan(start: 8, end: 10)) == .normal)
    }

    @Test func tooLittleHistoryIsNormal() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.5, seconds: 1)
        #expect(tracker.tone(for: AudioSpan(start: 0, end: 1)) == .normal)
    }

    @Test func louderThanUsualIsRaisedThenShout() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.03, seconds: 20)    // about -30 dBFS
        feed(tracker, rms: 0.07, seconds: 2)     // +7 dB
        #expect(tracker.tone(for: AudioSpan(start: 20, end: 22)) == .raised)
        feed(tracker, rms: 0.3, seconds: 2)      // +20 dB, -10 dBFS
        #expect(tracker.tone(for: AudioSpan(start: 22, end: 24)) == .shout)
    }

    @Test func loudOnlyRelativeToSilenceIsNotAShout() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.004, seconds: 20)   // about -48 dBFS, a quiet room
        feed(tracker, rms: 0.04, seconds: 2)     // +20 dB but only -28 dBFS
        #expect(tracker.tone(for: AudioSpan(start: 20, end: 22)) == .raised)
    }

    @Test func quieterThanUsualIsAWhisper() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.05, seconds: 20)
        feed(tracker, rms: 0.01, seconds: 2)     // -14 dB
        #expect(tracker.tone(for: AudioSpan(start: 20, end: 22)) == .whisper)
    }

    @Test func pausesInsideASentenceDoNotLowerIt() {
        let tracker = LoudnessTracker()
        feed(tracker, rms: 0.03, seconds: 20)
        for _ in 0..<10 {                         // loud words with silent gaps
            feed(tracker, rms: 0.3, seconds: 0.2)
            feed(tracker, rms: 0.0001, seconds: 0.1)
        }
        #expect(tracker.tone(for: AudioSpan(start: 20, end: 23)) == .shout)
    }
}
