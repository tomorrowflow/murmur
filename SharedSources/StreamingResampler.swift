import AVFoundation

/// Converts microphone tap buffers to mono Float samples at a target sample
/// rate using AVAudioConverter.
///
/// Replaces the previous naive decimation (`stride(by: Int(inRate/outRate))`),
/// which trapped with a zero stride for sub-16 kHz inputs (8 kHz Bluetooth HFP)
/// and produced pitch-shifted audio for non-integer ratios (44.1 kHz mics).
///
/// Not thread-safe: call `resample` from a single thread (the audio tap).
public final class StreamingResampler {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    public init?(targetSampleRate: Double) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        targetFormat = format
    }

    public func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let inputFormat = buffer.format

        if inputFormat.sampleRate == targetFormat.sampleRate && inputFormat.channelCount == 1 {
            guard let data = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        // The tap format can change mid-stream after a Bluetooth codec switch;
        // rebuild the converter whenever the incoming format differs.
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return [] }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var bufferConsumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if bufferConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            bufferConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if conversionError != nil { return [] }
        guard let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
