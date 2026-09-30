@preconcurrency import AVFoundation
import Observation

/// Joins one audio source to one transcriber and writes the result into a
/// CaptionFeed. Implements CaptionControlling so a UI can drive it without
/// knowing which sources or recogniser exist.
///
/// Optional collaborators, all injected by the app:
/// - `transcripts` receives every settled line (for saved transcripts).
/// - `correctText` rewrites caption text before it is shown (user corrections).
/// - `makeRecorder` returns a recorder when the user has turned recording on.
@MainActor
@Observable
public final class CaptionSession: CaptionControlling {
    public let feed: CaptionFeed
    public let sources: [CaptionSourceOption]
    public private(set) var activeSourceID: CaptionSourceOption.ID?
    public let languages: [CaptionLanguageOption]
    public private(set) var activeLanguageID: CaptionLanguageOption.ID

    /// A pause in settled speech longer than this starts a new transcript,
    /// so a day of "Phone calls" becomes one transcript per call.
    public var conversationGap: TimeInterval = 120

    @ObservationIgnored private let makeSource: (CaptionSourceOption.ID) -> AudioSource?
    @ObservationIgnored private let makeTranscriber: (CaptionLanguageOption.ID) -> SpeechTranscribing
    @ObservationIgnored private let languageChanged: (CaptionLanguageOption.ID) -> Void
    @ObservationIgnored private let makeRecorder: (CaptionSourceOption.ID) -> AudioRecording?
    @ObservationIgnored private let correctText: (String) -> String
    @ObservationIgnored private weak var transcripts: TranscriptSink?
    @ObservationIgnored private var running: (source: AudioSource, task: Task<Void, Never>, recorder: AudioRecording?)?
    @ObservationIgnored private var conversation: (id: TranscriptSession.ID, lastLineAt: Date)?

    /// - Parameters:
    ///   - sources: the options the UI may offer.
    ///   - makeSource: builds the audio source for an option id.
    ///   - languages: the caption languages the UI may offer; the first is
    ///     used when `languageID` is not one of them.
    ///   - makeTranscriber: builds a fresh recogniser for a language, for each run.
    ///   - languageChanged: told when the user picks another language (to save it).
    public init(sources: [CaptionSourceOption],
                languages: [CaptionLanguageOption],
                languageID: CaptionLanguageOption.ID? = nil,
                feed: CaptionFeed? = nil,
                makeSource: @escaping (CaptionSourceOption.ID) -> AudioSource?,
                makeTranscriber: @escaping (CaptionLanguageOption.ID) -> SpeechTranscribing,
                languageChanged: @escaping (CaptionLanguageOption.ID) -> Void = { _ in },
                transcripts: TranscriptSink? = nil,
                correctText: @escaping (String) -> String = { $0 },
                makeRecorder: @escaping (CaptionSourceOption.ID) -> AudioRecording? = { _ in nil }) {
        precondition(!languages.isEmpty, "CaptionSession needs at least one language")
        self.sources = sources
        self.languages = languages
        self.activeLanguageID = languages.first { $0.id == languageID }?.id ?? languages[0].id
        self.languageChanged = languageChanged
        self.feed = feed ?? CaptionFeed()
        self.makeSource = makeSource
        self.makeTranscriber = makeTranscriber
        self.transcripts = transcripts
        self.correctText = correctText
        self.makeRecorder = makeRecorder
    }

    public func start(_ sourceID: CaptionSourceOption.ID) {
        stop()
        guard let source = makeSource(sourceID) else {
            feed.setState(.failed("That audio source is not available."))
            return
        }
        activeSourceID = sourceID
        feed.setState(.preparing)
        let transcriber = makeTranscriber(activeLanguageID)
        let languageID = activeLanguageID
        let recorder = makeRecorder(sourceID)
        let feed = self.feed

        let task = Task { @MainActor [weak self] in
            do {
                Diagnostics.engine.info("starting source \(sourceID, privacy: .public) (recording \(recorder != nil, privacy: .public))")
                let audio = try await source.start()
                Diagnostics.engine.info("source \(sourceID, privacy: .public) started; listening")
                feed.setState(.listening)
                // Holds audio while the recogniser loads (a few seconds for the
                // Tamil model): 1,000 buffers is about 10 s of 10 ms buffers.
                // Only the oldest audio is dropped if it ever overflows.
                let (metered, meterFeed) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(1_000))
                // Tee: level meter and recorder on the way to the recogniser.
                let pump = Task.detached {
                    var lastLevelAt = ContinuousClock.now
                    var peak: Float = 0
                    var loggedFirstBuffer = false
                    var brokenAudio = BrokenAudioDetector()
                    for await buffer in audio {
                        if !loggedFirstBuffer {
                            loggedFirstBuffer = true
                            Diagnostics.engine.info("first audio buffer: \(buffer.format.description, privacy: .public)")
                        }
                        if let samples = buffer.floatChannelData?[0],
                           let brokenUp = brokenAudio.add(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)),
                                                          sampleRate: buffer.format.sampleRate) {
                            let block = brokenAudio.lastBlock.map { "\(Int($0.zeroShare * 100))% exact silence, \($0.gaps) gaps" } ?? ""
                            Diagnostics.engine.info("captured audio broken up: \(brokenUp, privacy: .public) (\(block, privacy: .public))")
                            Task { @MainActor in feed.setAudioBrokenUp(brokenUp) }
                        }
                        recorder?.write(buffer)
                        peak = max(peak, buffer.peakLevel)
                        if ContinuousClock.now - lastLevelAt > .milliseconds(100) {
                            let level = peak
                            // Fire-and-forget: awaiting the main actor here would stall
                            // audio on its way to the recogniser whenever the UI is busy.
                            Task { @MainActor in feed.setLevel(level) }
                            peak = 0
                            lastLevelAt = .now
                        }
                        meterFeed.yield(buffer)
                    }
                    meterFeed.finish()
                }
                for try await update in transcriber.transcribe(metered) {
                    self?.handle(update, sourceID: sourceID, languageID: languageID, recordingFile: recorder?.fileName)
                }
                pump.cancel()
                if !Task.isCancelled { feed.setState(.idle) }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                Diagnostics.engine.error("captioning failed: \(String(describing: error), privacy: .public)")
                feed.setState(.failed(error.localizedDescription))
            }
            if !Task.isCancelled { self?.finished(sourceID) }
        }
        running = (source, task, recorder)
    }

    public func stop() {
        guard let running else { return }
        self.running = nil
        running.source.stop()
        running.task.cancel()
        running.recorder?.finish()
        endConversation()
        activeSourceID = nil
        feed.setState(.idle)
    }

    public func clear() {
        feed.clear()
    }

    public func setLanguage(_ languageID: CaptionLanguageOption.ID) {
        guard languageID != activeLanguageID, languages.contains(where: { $0.id == languageID }) else { return }
        activeLanguageID = languageID
        languageChanged(languageID)
        if let sourceID = activeSourceID { start(sourceID) }
    }

    private func handle(_ update: TranscriptUpdate, sourceID: CaptionSourceOption.ID,
                        languageID: CaptionLanguageOption.ID, recordingFile: String?) {
        switch update {
        case .volatile(let text):
            feed.apply(.volatile(correctText(text)))
        case .final(let text, let audio, _):
            feed.apply(.final(correctText(text), audio: audio))
            record(text, audio: audio, sourceID: sourceID, languageID: languageID, recordingFile: recordingFile)
        }
    }

    /// Saves the recogniser's own words; corrections are applied on display,
    /// so later rules also fix old transcripts.
    private func record(_ heard: String, audio: AudioSpan?, sourceID: CaptionSourceOption.ID,
                        languageID: CaptionLanguageOption.ID, recordingFile: String?) {
        guard let transcripts, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        if let current = conversation, now.timeIntervalSince(current.lastLineAt) > conversationGap {
            transcripts.endSession(current.id, at: current.lastLineAt)
            conversation = nil
        }
        let id = conversation?.id ?? transcripts.beginSession(
            sourceID: sourceID,
            sourceTitle: sources.first { $0.id == sourceID }?.title ?? sourceID,
            languageID: languageID,
            recordingFile: recordingFile,
            at: now)
        transcripts.appendLine(heard, audio: audio, at: now, to: id)
        conversation = (id, now)
    }

    private func endConversation() {
        if let current = conversation { transcripts?.endSession(current.id, at: current.lastLineAt) }
        conversation = nil
    }

    private func finished(_ sourceID: CaptionSourceOption.ID) {
        guard activeSourceID == sourceID else { return }
        running?.recorder?.finish()
        running = nil
        endConversation()
        activeSourceID = nil
    }
}
