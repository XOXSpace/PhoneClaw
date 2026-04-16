import AVFoundation
import Foundation

final class AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sampleTime: AVAudioFramePosition?
    let hostTime: UInt64?

    init(
        buffer: AVAudioPCMBuffer,
        sampleTime: AVAudioFramePosition? = nil,
        hostTime: UInt64? = nil
    ) {
        self.buffer = buffer
        self.sampleTime = sampleTime
        self.hostTime = hostTime
    }

    var frameLength: AVAudioFrameCount {
        buffer.frameLength
    }

    var sampleRate: Double {
        buffer.format.sampleRate
    }

    var channelCount: AVAudioChannelCount {
        buffer.format.channelCount
    }

    func extractMonoSamples() -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData
        else {
            return []
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0 else { return [] }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        var mixed = Array(repeating: Float.zero, count: frameLength)
        for channelIndex in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameLength)
            for sampleIndex in 0..<frameLength {
                mixed[sampleIndex] += channel[sampleIndex]
            }
        }

        let scale = 1.0 / Float(channelCount)
        for index in mixed.indices {
            mixed[index] *= scale
        }
        return mixed
    }
}
