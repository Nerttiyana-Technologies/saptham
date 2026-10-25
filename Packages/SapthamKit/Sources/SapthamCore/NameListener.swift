@preconcurrency import AVFoundation
import Observation

/// Listens to the room for the user's name whatever is being captioned
/// (ADR 0001): during calls, "Everything playing", or with captions
/// stopped, when the room is otherwise not heard at all. Hands every line
/// it recognises, partial or settled, to `heard` (NameAlerts), and shows,
/// saves and logs none of it.
///
/// Follows its inputs by itself after `start()`: it re-checks whenever
/// something observable its closures read changes (the caption mode and
/// language) and on every settings change (the names).
///
/// Stands down while `isCoveredElsewhere` is true. Hidden coupling: that is
/// only safe because the app feeds Conversation captions to the same
/// NameAlerts (MacCaptionEngine's `lineHeard`); if Conversation captions
/// stop reaching NameAlerts, names go unheard in Conversation mode.
@MainActor
@Observable
public final class NameListener {
    public private(set) var isListening = false
    /// Why listening could not start (usually microphone permission).
    public private(set) var problem: String?

    @ObservationIgnored private let makeSource: () -> AudioSource
    @ObservationIgnored private let makeTranscriber: (CaptionLanguageOption.ID) -> SpeechTranscribing
    @ObservationIgnored private let languageID: () -> CaptionLanguageOption.ID
    @ObservationIgnored private let isWanted: () -> Bool
    @ObservationIgnored private let isCoveredElsewhere: () -> Bool
    @ObservationIgnored private let heard: (String) -> Void
    @ObservationIgnored private var running: (source: AudioSource, task: Task<Void, Never>,
                                              languageID: CaptionLanguageOption.ID, generation: Int)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var isStarted = false

    /// - Parameters:
    ///   - makeSource: the room microphone, a fresh one per start.
    ///   - makeTranscriber: a recogniser for a caption language.
    ///   - languageID: the language to listen in (the caption language).
    ///   - isWanted: name alerts are on, i.e. at least one name is set.
    ///   - isCoveredElsewhere: captions already hear the room (Conversation).
    ///   - heard: each recognised line.
    public init(makeSource: @escaping () -> AudioSource,
                makeTranscriber: @escaping (CaptionLanguageOption.ID) -> SpeechTranscribing,
                languageID: @escaping () -> CaptionLanguageOption.ID,
                isWanted: @escaping () -> Bool,
                isCoveredElsewhere: @escaping () -> Bool,
                heard: @escaping (String) -> Void) {
        self.makeSource = makeSource
        self.makeTranscriber = makeTranscriber
        self.languageID = languageID
        self.isWanted = isWanted
        self.isCoveredElsewhere = isCoveredElsewhere
        self.heard = heard
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        followAndTrack()
    }

    public func stop() {
        isStarted = false
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        stopListening()
    }

    /// Starts, stops or restarts listening to match the inputs. Does
    /// nothing when they did not change.
    public func follow() {
        guard isStarted else { return }
        let language = languageID()
        let wanted = isWanted() && !isCoveredElsewhere()
        if !wanted {
            stopListening()
        } else if running?.languageID != language {
            stopListening()
            startListening(in: language)
        }
    }

    private func followAndTrack() {
        withObservationTracking { follow() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.followAndTrack()
            }
        }
    }

    private func startListening(in language: CaptionLanguageOption.ID) {
        generation += 1
        let generation = generation
        let source = makeSource()
        let transcriber = makeTranscriber(language)
        let task = Task { @MainActor [weak self] in
            do {
                let audio = try await source.start()
                Diagnostics.engine.info("name listener: listening")
                self?.isListening = true
                self?.problem = nil
                for try await update in transcriber.transcribe(audio) {
                    // A stopped or replaced recogniser can still settle a
                    // last line; it belongs to a listener that has ended.
                    guard let self, running?.generation == generation else { break }
                    switch update {
                    case .volatile(let text), .final(let text, _, _): heard(text)
                    }
                }
            } catch is CancellationError {
            } catch {
                Diagnostics.engine.error("name listener stopped: \(String(describing: error), privacy: .public)")
                self?.problem = error.localizedDescription
            }
            guard let self, running?.generation == generation else { return }
            // Ended by itself (no audio, recogniser failed): forget it, so
            // the next change of inputs can start again.
            running = nil
            isListening = false
        }
        running = (source, task, language, generation)
    }

    private func stopListening() {
        guard let running else { return }
        self.running = nil
        running.source.stop()
        running.task.cancel()
        isListening = false
        Diagnostics.engine.info("name listener: stopped")
    }
}
