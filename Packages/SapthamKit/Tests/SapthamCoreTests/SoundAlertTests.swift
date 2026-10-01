import Testing
@testable import SapthamCore

struct SoundAlertJudgeTests {
    private func kind(_ id: String) -> SoundAlertKind { SoundAlertKind.all.first { $0.id == id }! }

    @Test func everyLabelIsOneTheClassifierKnows() {
        let known = Set(SoundClassifier.knownLabels)
        #expect(!known.isEmpty)
        for kind in SoundAlertKind.all {
            for label in kind.labels { #expect(known.contains(label), "\(kind.id): \(label)") }
        }
    }

    @Test func aSingleKnockIsEnough() {
        var judge = SoundAlertJudge(kinds: [kind("knock")])
        #expect(judge.add(["knock": 0.8], at: 0.5).map(\.kind.id) == ["knock"])
    }

    @Test func aSmokeAlarmMustKeepGoing() {
        var judge = SoundAlertJudge(kinds: [kind("smokeAlarm")])
        #expect(judge.add(["smoke_detector": 0.9], at: 0.5).isEmpty)
        #expect(judge.add(["smoke_detector": 0.1], at: 1.0).isEmpty)
        #expect(judge.add(["smoke_detector": 0.9], at: 1.5).isEmpty)
        #expect(judge.add(["smoke_detector": 0.9], at: 2.0).map(\.kind.id) == ["smokeAlarm"])
    }

    @Test func oneLongSoundIsOneAlert() {
        var judge = SoundAlertJudge(kinds: [kind("doorbell")])
        let times = stride(from: 0.5, through: 29.5, by: 0.5)
        let fired = times.flatMap { judge.add(["door_bell": 0.9], at: $0) }
        #expect(fired.count == 1)
        #expect(judge.add(["door_bell": 0.9], at: 31).count == 1)   // rings again after the quiet time
    }

    @Test func musicDoesNotRingThePhone() {
        // Scores a Tamil film song gave: the singer called a ringtone.
        var judge = SoundAlertJudge(kinds: [kind("phone")])
        let song: [String: Double] = ["telephone_bell_ringing": 0.91, "ringtone": 0.90, "music": 0.70]
        #expect((1...6).flatMap { judge.add(song, at: Double($0) / 2) }.isEmpty)
        let ringing: [String: Double] = ["telephone_bell_ringing": 0.91, "music": 0.1]
        #expect((7...9).flatMap { judge.add(ringing, at: Double($0) / 2) }.map(\.kind.id) == ["phone"])
    }

    @Test func soundsNotChosenNeverAlert() {
        var judge = SoundAlertJudge(kinds: [kind("doorbell")])
        #expect(judge.add(["knock": 1, "glass_breaking": 1], at: 0.5).isEmpty)
    }
}
