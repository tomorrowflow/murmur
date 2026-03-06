import AVFoundation

/// Plays short synthesized tones for push-to-talk start/stop feedback.
class PTTTonePlayer {
    static let shared = PTTTonePlayer()

    private let sampleRate: Double = 44100
    private let volume: Float = 0.35
    private var player: AVAudioPlayer?

    private init() {}

    /// Play a short rising two-tone beep (recording started).
    func playStartTone() {
        playTone(frequencies: [880, 1175], noteDuration: 0.07)
    }

    /// Play a short falling single-tone beep (recording stopped).
    func playStopTone() {
        playTone(frequencies: [784], noteDuration: 0.09)
    }

    /// Play a confirmation chirp (podcast interrupt received, processing started).
    func playInterruptTone() {
        playTone(frequencies: [660, 880, 660], noteDuration: 0.06)
    }

    private func playTone(frequencies: [Double], noteDuration: Double) {
        let totalSamples = Int(sampleRate * noteDuration) * frequencies.count
        var samples = [Float]()
        samples.reserveCapacity(totalSamples)

        for freq in frequencies {
            let framesPerNote = Int(sampleRate * noteDuration)
            let fadeFrames = min(Int(sampleRate * 0.005), framesPerNote)
            for i in 0..<framesPerNote {
                let t = Double(i) / sampleRate
                var sample = Float(sin(2.0 * .pi * freq * t)) * volume
                if i < fadeFrames {
                    sample *= Float(i) / Float(fadeFrames)
                }
                let remaining = framesPerNote - i
                if remaining < fadeFrames {
                    sample *= Float(remaining) / Float(fadeFrames)
                }
                samples.append(sample)
            }
        }

        let data = wavData(samples: samples, sampleRate: Int(sampleRate))
        do {
            player = try AVAudioPlayer(data: data)
            player?.play()
        } catch {
            print("PTTTonePlayer: failed to play tone: \(error)")
        }
    }

    private func wavData(samples: [Float], sampleRate: Int) -> Data {
        let bitsPerSample: Int = 16
        let channels: Int = 1
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * blockAlign

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16)
        appendUInt16(&data, 1) // PCM
        appendUInt16(&data, UInt16(channels))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(byteRate))
        appendUInt16(&data, UInt16(blockAlign))
        appendUInt16(&data, UInt16(bitsPerSample))
        // data chunk
        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            appendInt16(&data, int16)
        }
        return data
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }

    private func appendInt16(_ data: inout Data, _ value: Int16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
}
