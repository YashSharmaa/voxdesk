// Microphone capture: AVAudioEngine's input tap, converted to 16 kHz mono Float32 for Whisper, with the RMS
// of every buffer reported for the waveform. Voice processing stays off (it ducks other audio and glitches
// on start), and the engine only runs while dictating, so the mic indicator means VoxDesk is listening.
import Accelerate
import AVFoundation
import Foundation

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var buffer: [Float] = []
    private(set) var isRunning = false

    /// Called on the audio thread with the RMS (0...1) of each input buffer.
    var onLevel: (@Sendable (Float) -> Void)?

    static let maxSeconds = 600

    func start() throws {
        guard !isRunning else { return }
        lock.withLock { buffer.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoxDesk", code: 10, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.process(buf)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        return snapshot()
    }

    func snapshot() -> [Float] {
        lock.withLock { buffer }
    }

    var seconds: Double { Double(lock.withLock { buffer.count }) / 16000 }

    private func process(_ input: AVAudioPCMBuffer) {
        // Level for the waveform, from the first channel at the device rate.
        if let ch = input.floatChannelData?[0], input.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(input.frameLength))
            onLevel?(rms)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock {
            if buffer.count < Self.maxSeconds * 16000 { buffer.append(contentsOf: samples) }
        }
    }
}
