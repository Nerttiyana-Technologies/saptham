@preconcurrency import AVFoundation

/// A sound worth telling a deaf user about: the doorbell, a smoke alarm,
/// a baby crying. Detected with Apple's built-in sound classifier.
public struct SoundAlertKind: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// Built-in classifier labels that count as this sound.
    public let labels: [String]
    /// Score a window needs, 0 … 1.
    public var threshold: Double
    /// Windows in a row at or above `threshold` (0.5 s apart). 1 for
    /// sounds over in a moment (a knock); more for sounds that go on.
    public var windowsInARow: Int
    /// Labels the classifier also gives to music (it called Tamil singing a
    /// ringtone at 0.9): ignored while music scores high in the same window.
    public var confusedByMusic: Bool
    public var onByDefault: Bool
}

extension SoundAlertKind {
    /// Every sound the app can alert to, in the order Settings lists them.
    /// Ids are saved in the user's settings: renaming one turns it off.
    public static let all: [SoundAlertKind] = [
        SoundAlertKind(id: "doorbell", title: "Doorbell", systemImage: "bell.and.waves.left.and.right.fill",
                       labels: ["door_bell"], threshold: 0.6, windowsInARow: 1, confusedByMusic: false, onByDefault: true),
        SoundAlertKind(id: "knock", title: "Knocking", systemImage: "door.left.hand.closed",
                       labels: ["knock"], threshold: 0.7, windowsInARow: 1, confusedByMusic: false, onByDefault: true),
        SoundAlertKind(id: "smokeAlarm", title: "Smoke or fire alarm", systemImage: "flame.fill",
                       labels: ["smoke_detector"], threshold: 0.6, windowsInARow: 2, confusedByMusic: false, onByDefault: true),
        SoundAlertKind(id: "alarm", title: "Alarm clock", systemImage: "alarm.fill",
                       labels: ["alarm_clock"], threshold: 0.7, windowsInARow: 2, confusedByMusic: false, onByDefault: true),
        SoundAlertKind(id: "whistle", title: "Whistle (pressure cooker, kettle)", systemImage: "cooktop.fill",
                       labels: ["whistling"], threshold: 0.7, windowsInARow: 2, confusedByMusic: true, onByDefault: true),
        SoundAlertKind(id: "baby", title: "Baby crying", systemImage: "figure.and.child.holdinghands",
                       labels: ["baby_crying"], threshold: 0.7, windowsInARow: 2, confusedByMusic: false, onByDefault: true),
        SoundAlertKind(id: "shouting", title: "Someone shouting", systemImage: "person.wave.2.fill",
                       labels: ["shout", "yell", "screaming", "children_shouting"], threshold: 0.7, windowsInARow: 2,
                       confusedByMusic: true, onByDefault: true),
        SoundAlertKind(id: "phone", title: "Phone ringing", systemImage: "phone.arrow.down.left.fill",
                       labels: ["telephone_bell_ringing", "ringtone"], threshold: 0.8, windowsInARow: 3,
                       confusedByMusic: true, onByDefault: false),
        SoundAlertKind(id: "dog", title: "Dog barking", systemImage: "dog.fill",
                       labels: ["dog_bark", "dog_bow_wow", "dog_growl"], threshold: 0.7, windowsInARow: 2,
                       confusedByMusic: false, onByDefault: false),
        SoundAlertKind(id: "siren", title: "Siren", systemImage: "light.beacon.max.fill",
                       labels: ["siren", "ambulance_siren", "police_siren", "fire_engine_siren", "civil_defense_siren",
                                "emergency_vehicle"],
                       threshold: 0.7, windowsInARow: 3, confusedByMusic: true, onByDefault: false),
        SoundAlertKind(id: "glass", title: "Glass breaking", systemImage: "wineglass.fill",
                       labels: ["glass_breaking"], threshold: 0.7, windowsInARow: 1, confusedByMusic: false, onByDefault: false),
    ]
}

/// One detected sound.
public struct SoundAlert: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let kind: SoundAlertKind
    public let confidence: Double
    public let time: Date

    public init(kind: SoundAlertKind, confidence: Double, time: Date = Date()) {
        self.kind = kind
        self.confidence = confidence
        self.time = time
    }
}

/// Turns classifier windows into alerts. Pure logic over scores, so it can
/// be tested without audio.
///
/// - A kind fires after `windowsInARow` windows at or above its threshold.
/// - Then it stays quiet for `quietSeconds`, so one ringing doorbell or a
///   whistle that goes on for a minute is one alert, not dozens.
/// - Kinds the classifier confuses with music are ignored in windows where
///   music scores `musicToIgnore` or more.
public struct SoundAlertJudge: Sendable {
    public var kinds: [SoundAlertKind]
    public var quietSeconds: Double = 30
    public var musicToIgnore = 0.5

    private var runs: [SoundAlertKind.ID: Int] = [:]
    private var lastFired: [SoundAlertKind.ID: Double] = [:]

    public init(kinds: [SoundAlertKind]) {
        self.kinds = kinds
    }

    /// `time` is in seconds on any steadily increasing clock.
    public mutating func add(_ window: [String: Double], at time: Double) -> [(kind: SoundAlertKind, confidence: Double)] {
        let music = window.highest(of: ["music"] + SoundSceneDetector.instruments)
        var fired: [(SoundAlertKind, Double)] = []
        for kind in kinds {
            let score = window.highest(of: kind.labels)
            let heard = score >= kind.threshold && !(kind.confusedByMusic && music >= musicToIgnore)
            let run = heard ? (runs[kind.id] ?? 0) + 1 : 0
            runs[kind.id] = run
            guard run >= kind.windowsInARow else { continue }
            if let last = lastFired[kind.id], time - last < quietSeconds { continue }
            lastFired[kind.id] = time
            runs[kind.id] = 0
            fired.append((kind, score))
        }
        return fired
    }
}

/// Listens to a stream of audio for the given kinds of sound.
public final class SoundAlertDetector: Sendable {
    /// 1 s windows with half overlap: a score every 0.5 s, short enough to
    /// catch a single knock.
    public let classifier = SoundClassifier(windowSeconds: 1.0)
    private let kinds: [SoundAlertKind]

    public init(kinds: [SoundAlertKind]) {
        self.kinds = kinds
    }

    /// Finishes after the audio stream finishes.
    public func alerts(in audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<SoundAlert> {
        let windows = classifier.windows(of: audio)
        let kinds = self.kinds
        let interval = classifier.windowSeconds * (1 - classifier.overlap)
        return AsyncStream { output in
            let task = Task.detached {
                var judge = SoundAlertJudge(kinds: kinds)
                var time = 0.0
                for await window in windows {
                    time += interval
                    // Near misses too, at debug level, so thresholds can be
                    // tuned against the user's own doorbell and cooker.
                    if kinds.contains(where: { window.highest(of: $0.labels) >= 0.3 }) {
                        Diagnostics.engine.debug("alert window: \(window.top(5), privacy: .public)")
                    }
                    for (kind, confidence) in judge.add(window, at: time) {
                        Diagnostics.engine.info("sound alert: \(kind.id, privacy: .public) \(confidence, format: .fixed(precision: 2)) (\(window.top(3), privacy: .public))")
                        output.yield(SoundAlert(kind: kind, confidence: confidence))
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}
