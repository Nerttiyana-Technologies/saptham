@preconcurrency import AVFoundation
import Testing
@testable import SapthamCore

@MainActor
struct CaptionFeedTests {
    @Test func volatileTextIsReplacedThenSettled() {
        let feed = CaptionFeed()
        feed.apply(.volatile("Hello"))
        feed.apply(.volatile("Hello Suresh"))
        #expect(feed.partial == "Hello Suresh")
        #expect(feed.lines.isEmpty)

        feed.apply(.final(" Hello Suresh. "))
        #expect(feed.partial.isEmpty)
        #expect(feed.lines.map(\.text) == ["Hello Suresh."])
    }

    @Test func emptyFinalAddsNoLine() {
        let feed = CaptionFeed()
        feed.apply(.final("   "))
        #expect(feed.lines.isEmpty)
    }

    @Test func oldLinesAreDropped() {
        let feed = CaptionFeed(maxLines: 2)
        for word in ["one", "two", "three"] { feed.apply(.final(word)) }
        #expect(feed.lines.map(\.text) == ["two", "three"])
    }

    @Test func leavingListeningResetsLevel() {
        let feed = CaptionFeed()
        feed.setState(.listening)
        feed.setLevel(2)
        #expect(feed.level == 1)
        feed.setState(.idle)
        #expect(feed.level == 0)
    }
}

struct AudioFormatConverterTests {
    @Test func tapFormatConvertsToRecogniserFormat() throws {
        let tap = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let recogniser = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: 4_800))
        input.frameLength = 4_800   // 100 ms
        let converter = try AudioFormatConverter(from: tap, to: recogniser)

        // The resampler holds back a short priming tail, so judge a 2 s stream
        // rather than one buffer: only that small delay may be missing.
        var produced = 0
        for _ in 0..<20 {
            let output = try #require(converter.convert(input))
            #expect(output.format == recogniser)
            produced += Int(output.frameLength)
        }
        #expect(produced <= 32_000)
        #expect(produced >= 32_000 - 320)   // at most 20 ms held back
    }
}

@MainActor
struct CaptionFeedAudioActivityTests {
    @Test func silentBuffersDoNotCountAsAudio() async throws {
        let feed = CaptionFeed()
        feed.setLevel(0)
        #expect(!feed.isReceivingAudio)
        feed.setLevel(0.2)
        #expect(feed.isReceivingAudio)
        // Silence keeps arriving after the call: activity must lapse.
        for _ in 0..<20 {
            feed.setLevel(0)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!feed.isReceivingAudio)
    }
}
