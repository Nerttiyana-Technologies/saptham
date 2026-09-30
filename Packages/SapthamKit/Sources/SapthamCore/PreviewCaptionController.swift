import Foundation
import Observation

/// A stand-in engine for SwiftUI previews and UI work: plays scripted
/// captions without audio, permissions, or a speech model.
@MainActor
@Observable
public final class PreviewCaptionController: CaptionControlling {
    public let feed = CaptionFeed()
    public let sources: [CaptionSourceOption]
    public private(set) var activeSourceID: CaptionSourceOption.ID?
    @ObservationIgnored private var script: Task<Void, Never>?

    public nonisolated static let sampleSources = [
        CaptionSourceOption(id: "calls", title: "Phone calls", detail: "Calls from iPhone answered on this Mac", systemImage: "phone.fill"),
        CaptionSourceOption(id: "microphone", title: "Conversation", detail: "People talking near this Mac", systemImage: "person.2.wave.2.fill"),
        CaptionSourceOption(id: "system", title: "Everything playing", detail: "Meetings, videos and any app's sound", systemImage: "speaker.wave.2.fill"),
    ]

    public nonisolated static let sampleSentences = [
        "Hello, is this Suresh?",
        "Your appointment with the audiologist is on Tuesday at 11:30 in the morning.",
        "Please bring your processor and the charger.",
        "The bank has sent your new debit card to the Chennai branch.",
        "Thank you, have a good day.",
    ]

    public init(sources: [CaptionSourceOption] = PreviewCaptionController.sampleSources,
                prefilled: Bool = true) {
        self.sources = sources
        if prefilled {
            for sentence in Self.sampleSentences.prefix(3) { feed.apply(.final(sentence)) }
            feed.apply(.volatile("The bank has sent your new"))
        }
    }

    public func start(_ sourceID: CaptionSourceOption.ID) {
        stop()
        activeSourceID = sourceID
        feed.setState(.listening)
        script = Task { @MainActor [feed] in
            while !Task.isCancelled {
                for sentence in Self.sampleSentences {
                    let words = sentence.split(separator: " ")
                    for count in 1...words.count {
                        guard !Task.isCancelled else { return }
                        feed.apply(.volatile(words.prefix(count).joined(separator: " ")))
                        feed.setLevel(Float.random(in: 0.3...0.9))
                        try? await Task.sleep(for: .milliseconds(220))
                    }
                    feed.apply(.final(sentence))
                    feed.setLevel(0.05)
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
        }
    }

    public func stop() {
        script?.cancel()
        script = nil
        activeSourceID = nil
        feed.setState(.idle)
    }

    public func clear() {
        feed.clear()
    }
}
