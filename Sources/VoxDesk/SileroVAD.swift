// Voice activity detection with Silero VAD v6 (MIT), using the Core ML build published at
// huggingface.co/FluidInference/silero-vad-coreml (MIT). The model takes 256 ms of new 16 kHz audio plus
// 64 samples of context and an LSTM state, and returns one speech probability for the 256 ms.
import CoreML
import Foundation

final class SileroVAD: @unchecked Sendable {
    static let chunk = 4096          // 256 ms at 16 kHz
    static let context = 64
    static let stateSize = 128
    static let repo = "FluidInference/silero-vad-coreml"
    static let revision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    static let modelName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    static let files = ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]

    private var model: MLModel?
    private let lock = NSLock()

    var modelURL: URL { Paths.vad.appendingPathComponent(Self.modelName, isDirectory: true) }

    var isDownloaded: Bool {
        Self.files.allSatisfy { FileManager.default.fileExists(atPath: modelURL.appendingPathComponent($0).path) }
    }

    /// Downloads the five files of the compiled model (about 2 MB) if they are missing, then loads it on the CPU,
    /// where a model this small is fastest and leaves the Neural Engine to Whisper.
    func load() async throws {
        if lock.withLock({ model != nil }) { return }
        if !isDownloaded {
            let fm = FileManager.default
            let tmp = Paths.vad.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
            for file in Self.files {
                let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(Self.modelName)/\(file)")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "VoxDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not download the voice activity model (\(file))."])
                }
                let dest = tmp.appendingPathComponent(file)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            }
            try? fm.removeItem(at: modelURL)
            try fm.moveItem(at: tmp, to: modelURL)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: modelURL, configuration: config)
        lock.withLock { model = loaded }
    }

    /// Speech probability for each 256 ms chunk of `samples` (16 kHz mono). The last chunk is zero padded.
    func probabilities(_ samples: [Float]) throws -> [Float] {
        guard let model = lock.withLock({ model }) else { return [] }
        guard !samples.isEmpty else { return [] }
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.chunk + Self.context)], dataType: .float32)
        let hidden = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        let cell = try MLMultiArray(shape: [1, NSNumber(value: Self.stateSize)], dataType: .float32)
        let inPtr = input.dataPointer.assumingMemoryBound(to: Float.self)
        let hPtr = hidden.dataPointer.assumingMemoryBound(to: Float.self)
        let cPtr = cell.dataPointer.assumingMemoryBound(to: Float.self)
        hPtr.update(repeating: 0, count: Self.stateSize)
        cPtr.update(repeating: 0, count: Self.stateSize)
        var ctx = [Float](repeating: 0, count: Self.context)
        var out: [Float] = []
        var start = 0
        while start < samples.count {
            let end = min(start + Self.chunk, samples.count)
            inPtr.update(repeating: 0, count: Self.chunk + Self.context)
            ctx.withUnsafeBufferPointer { inPtr.update(from: $0.baseAddress!, count: Self.context) }
            samples.withUnsafeBufferPointer { buf in
                (inPtr + Self.context).update(from: buf.baseAddress! + start, count: end - start)
            }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: input),
                "hidden_state": MLFeatureValue(multiArray: hidden),
                "cell_state": MLFeatureValue(multiArray: cell),
            ])
            let result = try model.prediction(from: features)
            guard let prob = result.featureValue(for: "vad_output")?.multiArrayValue,
                  let newH = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let newC = result.featureValue(for: "new_cell_state")?.multiArrayValue else { break }
            out.append(prob[0].floatValue)
            for i in 0..<Self.stateSize {
                hPtr[i] = newH[i].floatValue
                cPtr[i] = newC[i].floatValue
            }
            // The next chunk's context is the last 64 samples fed to the model.
            let fed = Array(UnsafeBufferPointer(start: inPtr, count: Self.chunk + Self.context))
            ctx = Array(fed.suffix(Self.context))
            start = end
        }
        return out
    }
}
