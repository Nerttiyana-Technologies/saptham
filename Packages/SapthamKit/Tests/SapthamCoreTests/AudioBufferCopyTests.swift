@preconcurrency import AVFoundation
import Testing
@testable import SapthamCore

struct AudioBufferCopyTests {
    private func buffer(channels: AVAudioChannelCount, value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 4_096
        for channel in 0..<Int(channels) {
            for frame in 0..<4_096 { buffer.floatChannelData![channel][frame] = value + Float(channel) }
        }
        return buffer
    }

    /// The tap reuses its buffer for later sound; a queued copy must keep
    /// the sound it was made from.
    @Test func aCopyKeepsItsSoundWhenTheOriginalIsReused() throws {
        let original = try buffer(channels: 1, value: 0.25)
        let copy = try #require(original.ownedCopy())
        for frame in 0..<4_096 { original.floatChannelData![0][frame] = -0.5 }
        #expect(copy.frameLength == 4_096)
        #expect(copy.floatChannelData![0] != original.floatChannelData![0])
        #expect((0..<4_096).allSatisfy { copy.floatChannelData![0][$0] == 0.25 })
    }

    @Test func copiesEveryChannel() throws {
        let copy = try #require(try buffer(channels: 2, value: 0.1).ownedCopy())
        #expect(copy.floatChannelData![0][100] == 0.1)
        #expect(copy.floatChannelData![1][100] == 1.1)
    }

    @Test func anEmptyBufferHasNoCopy() throws {
        let empty = try buffer(channels: 1, value: 0)
        empty.frameLength = 0
        #expect(empty.ownedCopy() == nil)
    }
}
