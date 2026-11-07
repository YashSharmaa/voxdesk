// The one place speech becomes text. A singleton actor owns the selected recogniser (Parakeet or Whisper; only
// the selected one is loaded and kept warm) and the voice activity model, and runs the same steps for the app
// and for `VoxDesk --transcribe`: energy gate -> Silero VAD gate and trim -> the recogniser, with the glossary
// as keyword boosting (Parakeet) or as a prompt (Whisper) -> hallucination filter.
import CoreML
import Foundation
import WhisperKit

enum EnginePhase: Equatable, Sendable {
    case idle
    case downloading(Double)       // 0...1
    case optimising                // first Core ML specialisation for this Mac
    case loading
    case ready
    case failed(String)
}

struct LoadReport: Sendable {
    var engine: EngineChoice = .whisper
    var model: String
    var downloadSeconds: Double = 0
    var prewarmSeconds: Double = 0   // Core ML specialisation (only when we think the cache is cold)
    var loadSeconds: Double = 0      // load into memory
    var warmupSeconds: Double = 0    // first inference on silence
    var vadLoadSeconds: Double = 0
    var wasCold = false
    var alreadyLoaded = false
    var total: Double { downloadSeconds + prewarmSeconds + loadSeconds + warmupSeconds + vadLoadSeconds }
}

struct PipelineOptions: Sendable {
    var language: String?            // nil detects
    var vocabulary: String
    var partial = false              // a live preview pass: fewer fallbacks, no long-audio chunking
    var timestamps = false           // segment timings
    var extraPrompt = ""             // a sentence appended after the glossary sentence (Hinglish style)

    static func fromSettings(partial: Bool = false) -> PipelineOptions {
        PipelineOptions(language: Settings.language.code, vocabulary: Settings.vocabulary, partial: partial,
                        extraPrompt: Settings.language.stylePrompt)
    }
}

struct PipelineResult: Sendable {
    var text: String
    var language: String?
    var skipped: String?             // why nothing was produced, if nothing was
    var audioSeconds: Double
    var speechSeconds: Double = 0
    var maxSpeechProb: Float = 0
    var vadSeconds: Double = 0
    var whisperSeconds: Double = 0   // time in the recogniser (Whisper or Parakeet)
    var boostSeconds: Double = 0     // Parakeet keyword boosting
    var boosted: [String] = []       // glossary terms keyword boosting wrote into the text
    var encodeSeconds: Double = 0
    var decodeSeconds: Double = 0
    var tokens = 0
    var promptTokens = 0
    var fallbacks = 0
    var totalSeconds: Double = 0
    /// Segments with start and end in samples from the start of the audio passed in (only with `timestamps`).
    var segments: [Segment] = []

    struct Segment: Sendable, Equatable {
        var text: String
        var start: Int
        var end: Int
    }
}

/// Lets a caller stop a running pass early (a live preview pass when the user lets go of the key).
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

actor SpeechEngine {
    static let shared = SpeechEngine()

    // Voice activity thresholds. A 256 ms chunk is speech at or above `speechProb`; with no chunk that high the
    // clip is treated as silence and nothing is pasted (the research's "under 0.3, paste nothing", made a little
    // stricter because the unified 256 ms model reports the noisy-OR of eight 32 ms frames).
    static let speechProb: Float = 0.5
    static let edgeProb: Float = 0.3
    static let silenceDBFS: Float = -55

    private var kit: WhisperKit?
    private(set) var activeEngine: EngineChoice = .whisper
    private var warmVocabulary = ""
    #if canImport(FluidAudio)
    private let parakeet = ParakeetEngine()
    #endif
    private var loadedModel: String?
    private let vad = SileroVAD()
    private var phaseHandler: (@Sendable (EnginePhase) -> Void)?
    // WhisperKit is not safe to run twice at once on one instance, and actor methods interleave at awaits,
    // so passes queue here.
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
    }
    private(set) var phase: EnginePhase = .idle {
        didSet { phaseHandler?(phase) }
    }

    func onPhase(_ handler: @escaping @Sendable (EnginePhase) -> Void) {
        phaseHandler = handler
        handler(phase)
    }

    var isReady: Bool { isLoaded && phase == .ready }

    private var isLoaded: Bool {
        #if canImport(FluidAudio)
        if activeEngine == .parakeet { return parakeet.isLoaded }
        #endif
        return kit != nil
    }

    // MARK: Loading

    static func folder(for model: String) -> URL {
        Paths.models.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
    }

    private static func completeMarker(_ model: String) -> URL {
        folder(for: model).appendingPathComponent(".voxdesk-complete")
    }

    /// Core ML caches the device-specialised model outside the app, and evicts it on OS updates. We remember
    /// that a model was specialised on this OS build, and only prewarm (load, unload, load) when we have not.
    private static func specialisedMarker(_ model: String) -> URL {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let units = computeOptions()
        // Core ML keeps that cache per app (under ~/Library/Caches/<bundle id or process name>), so the app and
        // the command line each specialise once.
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return Paths.support.appendingPathComponent(
            ".specialised-\(owner)-\(model)-\(build)-\(units.audioEncoderCompute.rawValue)\(units.textDecoderCompute.rawValue)")
    }

    static func isDownloaded(_ model: String) -> Bool {
        FileManager.default.fileExists(atPath: completeMarker(model).path)
    }

    /// Loads `engine` (with Whisper checkpoint `model`), unloading the other engine so only the selected one
    /// stays in memory. Loads and transcriptions queue behind each other, so picking an engine or model twice in
    /// a row, or mid-dictation, is safe.
    @discardableResult
    func load(engine: EngineChoice, model: String, force: Bool = false,
              vocabulary: String = Settings.vocabulary) async throws -> LoadReport {
        await acquire()
        warmVocabulary = vocabulary
        do {
            if force, let old = kit {
                await old.unloadModels()
                kit = nil
                loadedModel = nil
            }
            #if canImport(FluidAudio)
            if engine == .parakeet {
                let report = try await loadParakeetLocked()
                release()
                return report
            }
            await parakeet.unload()
            #endif
            activeEngine = .whisper
            let report = try await loadLocked(model: model)
            release()
            return report
        } catch {
            release()
            throw error
        }
    }

    #if canImport(FluidAudio)
    private func loadParakeetLocked() async throws -> LoadReport {
        var report = LoadReport(engine: .parakeet, model: "parakeet-tdt-0.6b-v2")
        if activeEngine == .parakeet, parakeet.isLoaded {
            report.alreadyLoaded = true
            return report
        }
        if let old = kit {
            await old.unloadModels()
            kit = nil
            loadedModel = nil
        }
        activeEngine = .parakeet
        do {
            var t = Date()
            try await vad.load()
            report.vadLoadSeconds = Date().timeIntervalSince(t)
            let cold = !ParakeetEngine.isDownloaded || !ParakeetEngine.ctcDownloaded
            report.wasCold = cold
            phase = cold ? .downloading(0) : .loading
            let handler = phaseHandler
            t = Date()
            // FluidAudio reports progress while it checks files already on disk too; only show a real download.
            try await parakeet.load(progress: { f in if cold { handler?(.downloading(f)) } })
            if cold { report.downloadSeconds = Date().timeIntervalSince(t) } else { report.loadSeconds = Date().timeIntervalSince(t) }
            phase = .loading
            t = Date()
            await warmUpLocked()
            report.warmupSeconds = Date().timeIntervalSince(t)
            phase = .ready
            return report
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }
    #endif

    private func loadLocked(model: String) async throws -> LoadReport {
        var report = LoadReport(model: model)
        if kit != nil, loadedModel == model {
            report.alreadyLoaded = true
            return report
        }
        if let old = kit {
            await old.unloadModels()
            kit = nil
            loadedModel = nil
        }

        do {
            var t = Date()
            try await vad.load()
            report.vadLoadSeconds = Date().timeIntervalSince(t)

            let folder = Self.folder(for: model)
            if !Self.isDownloaded(model) {
                phase = .downloading(0)
                t = Date()
                let handler = phaseHandler
                let downloaded = try await WhisperKit.download(
                    variant: model,
                    downloadBase: Paths.models,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { progress in
                        handler?(.downloading(progress.fractionCompleted))
                    }
                )
                guard downloaded.standardizedFileURL.path == folder.standardizedFileURL.path else {
                    throw NSError(domain: "VoxDesk", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "Model downloaded to an unexpected place: \(downloaded.lastPathComponent)"])
                }
                FileManager.default.createFile(atPath: Self.completeMarker(model).path, contents: Data())
                report.downloadSeconds = Date().timeIntervalSince(t)
            }

            let cold = !FileManager.default.fileExists(atPath: Self.specialisedMarker(model).path)
            report.wasCold = cold
            phase = cold ? .optimising : .loading
            let config = WhisperKitConfig(
                model: model,
                modelFolder: folder.path,
                tokenizerFolder: Paths.models,
                computeOptions: Self.computeOptions(),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: false
            )
            let whisper = try await WhisperKit(config)
            if cold {
                t = Date()
                try await whisper.prewarmModels()
                report.prewarmSeconds = Date().timeIntervalSince(t)
                FileManager.default.createFile(atPath: Self.specialisedMarker(model).path, contents: Data())
                phase = .loading
            }
            t = Date()
            try await whisper.loadModels()
            report.loadSeconds = Date().timeIntervalSince(t)
            kit = whisper
            loadedModel = model

            t = Date()
            await warmUpLocked()
            report.warmupSeconds = Date().timeIntervalSince(t)
            phase = .ready
            return report
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Runs half a second of silence through the encoder and decoder so the first real dictation is fast.
    /// Called after loading and after the Mac wakes.
    func warmUp() async {
        await acquire()
        await warmUpLocked()
        release()
    }

    private func warmUpLocked() async {
        #if canImport(FluidAudio)
        if activeEngine == .parakeet {
            // One pass with the glossary also builds the keyword-boosting session for it.
            await parakeet.warmUp(terms: Vocabulary.terms(from: warmVocabulary))
            return
        }
        #endif
        guard let kit else { return }
        var options = DecodingOptions(verbose: false, task: .transcribe, language: "en",
                                      temperatureFallbackCount: 0, sampleLength: 8,
                                      usePrefillPrompt: true, withoutTimestamps: true, windowClipTime: 0)
        options.concurrentWorkerCount = 1
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 8000), decodeOptions: options)
    }

    func unload() async {
        await acquire()
        if let kit { await kit.unloadModels() }
        #if canImport(FluidAudio)
        await parakeet.unload()
        #endif
        kit = nil
        loadedModel = nil
        phase = .idle
        release()
    }

    // MARK: Transcription

    func transcribe(_ samples: [Float], options: PipelineOptions, abort: AbortFlag? = nil) async throws -> PipelineResult {
        await acquire()
        do {
            let r = try await transcribeLocked(samples, options: options, abort: abort)
            release()
            return r
        } catch {
            release()
            throw error
        }
    }

    private func transcribeLocked(_ samples: [Float], options: PipelineOptions, abort: AbortFlag?) async throws -> PipelineResult {
        let start = Date()
        let audioSeconds = Double(samples.count) / 16000
        var result = PipelineResult(text: "", audioSeconds: audioSeconds)
        func done(_ reason: String?) -> PipelineResult {
            result.skipped = reason
            result.totalSeconds = Date().timeIntervalSince(start)
            return result
        }

        guard isLoaded else { throw WhisperError.modelsUnavailable("The model is not loaded yet.") }
        guard samples.count >= 4000 else { return done("too short") }   // under 0.25 s

        // 1. Energy gate: a clip whose loudest 32 ms frame is near digital silence has no speech in it.
        if Self.peakFrameDBFS(samples) < Self.silenceDBFS { return done("silence (energy)") }

        // 2. Voice activity gate and trim.
        let tv = Date()
        let probs = try vad.probabilities(samples)
        result.vadSeconds = Date().timeIntervalSince(tv)
        result.maxSpeechProb = probs.max() ?? 0
        if DictationStream.debug, !options.partial {
            FileHandle.standardError.write(Data("[vad] \(probs.map { String(format: "%.2f", $0) }.joined(separator: " "))\n".utf8))
        }
        let speechChunks = probs.filter { $0 >= Self.speechProb }.count
        result.speechSeconds = Double(speechChunks) * Double(SileroVAD.chunk) / 16000
        guard speechChunks > 0 else { return done("no speech (voice activity)") }
        let first = probs.firstIndex { $0 >= Self.edgeProb } ?? 0
        let last = probs.lastIndex { $0 >= Self.edgeProb } ?? probs.count - 1
        // Keep 256 ms either side of the speech; anything beyond that is silence over 300 ms and goes.
        let lo = max(0, (first - 1) * SileroVAD.chunk)
        let hi = min(samples.count, (last + 2) * SileroVAD.chunk)
        let trimmed = Array(samples[lo..<hi])

        #if canImport(FluidAudio)
        if activeEngine == .parakeet {
            if abort?.isSet == true { return done("aborted") }
            // Live previews skip keyword boosting; the passes whose text is kept use it.
            let terms = options.partial ? [] : Vocabulary.terms(from: options.vocabulary)
            let out = try await parakeet.transcribe(trimmed, terms: terms)
            result.whisperSeconds = out.asrSeconds
            result.boostSeconds = out.boostSeconds
            result.boosted = out.replaced
            result.language = "en"
            let text = Vocabulary.applySpelling(Self.clean(out.text), terms: Vocabulary.terms(from: options.vocabulary))
            if Self.isLikelyHallucination(text, prompt: "", speechSeconds: result.speechSeconds) {
                return done("filtered hallucination: \(text)")
            }
            result.text = text
            return done(text.isEmpty ? "empty transcript" : nil)
        }
        #endif
        guard let kit, let tokenizer = kit.tokenizer else { throw WhisperError.modelsUnavailable("The model is not loaded yet.") }

        // 3. Whisper, with the glossary as the previous sentence.
        var decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: options.language,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: options.partial ? 0 : 3,
            usePrefillPrompt: true,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: !options.timestamps,
            // WhisperKit skips any window shorter than this, so its 1 s default would drop a quick "yes".
            windowClipTime: 0.1,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            chunkingStrategy: trimmed.count > 30 * 16000 && !options.partial ? .vad : ChunkingStrategy.none
        )
        let prompt = [Vocabulary.promptSentence(from: options.vocabulary), options.extraPrompt]
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !prompt.isEmpty {
            decode.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        result.promptTokens = decode.promptTokens?.count ?? 0
        if abort?.isSet == true { return done("aborted") }
        let tw = Date()
        // Returning false from the progress callback stops decoding early.
        let callback: TranscriptionCallback? = abort.map { flag in { @Sendable _ in flag.isSet ? false : nil } }
        let results = try await kit.transcribe(audioArray: trimmed, decodeOptions: decode, callback: callback)
        if abort?.isSet == true { return done("aborted") }
        result.whisperSeconds = Date().timeIntervalSince(tw)
        result.language = results.first?.language
        result.encodeSeconds = results.reduce(0) { $0 + $1.timings.encoding }
        result.decodeSeconds = results.reduce(0) { $0 + $1.timings.decodingLoop }
        result.fallbacks = Int(results.reduce(0) { $0 + $1.timings.totalDecodingFallbacks })
        result.tokens = results.flatMap(\.segments).reduce(0) { $0 + $1.tokens.count }

        // 4. Drop what Whisper invents: repetitive segments, and stock phrases when there was little speech.
        let segments = results.flatMap(\.segments).filter { $0.compressionRatio <= 2.4 || $0.text.count < 20 }
        var text = segments.map(\.text).joined()
        text = Self.clean(text)
        if options.timestamps {
            result.segments = segments.map {
                PipelineResult.Segment(text: Self.clean($0.text), start: lo + Int($0.start * 16000), end: lo + Int($0.end * 16000))
            }.filter { !$0.text.isEmpty }
        }
        if Self.isLikelyHallucination(text, prompt: prompt, speechSeconds: result.speechSeconds) {
            return done("filtered hallucination: \(text)")
        }
        result.text = text
        return done(text.isEmpty ? "empty transcript" : nil)
    }

    // MARK: Helpers

    /// The encoder runs on the GPU and the decoder on the Neural Engine: measured on an M5 Max, the encoder takes
    /// 131 ms per 30 s window on the GPU against 501 ms on the Neural Engine, while the token-by-token decoder is
    /// faster on the Neural Engine. VOXDESK_ENCODER / VOXDESK_DECODER = ane | gpu | cpu | all override them.
    static func computeOptions() -> ModelComputeOptions {
        func units(_ name: String) -> MLComputeUnits? {
            switch ProcessInfo.processInfo.environment[name]?.lowercased() {
            case "ane": return .cpuAndNeuralEngine
            case "gpu": return .cpuAndGPU
            case "cpu": return .cpuOnly
            case "all": return .all
            default: return nil
            }
        }
        return ModelComputeOptions(audioEncoderCompute: units("VOXDESK_ENCODER") ?? (Settings.encoderOnGPU ? .cpuAndGPU : .cpuAndNeuralEngine),
                                   textDecoderCompute: units("VOXDESK_DECODER") ?? .cpuAndNeuralEngine)
    }

    static func peakFrameDBFS(_ samples: [Float]) -> Float {
        let frame = 512
        var peak: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(i + frame, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            peak = max(peak, (sum / Float(end - i)).squareRoot())
            i = end
        }
        return 20 * log10(max(peak, 1e-9))
    }

    static func clean(_ raw: String) -> String {
        var text = raw
        // Strip any special tokens that slipped through, like <|endoftext|>.
        while let r = text.range(of: "<\\|[^|]*\\|>", options: .regularExpression) { text.removeSubrange(r) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let stockPhrases: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching",
        "thank you for watching.", "you", "bye", "bye.", "okay.", "so", "the end", "subscribe",
        "please subscribe", "like and subscribe", "music", "[music]", "(music)", "[blank_audio]", "...",
    ]

    static func isLikelyHallucination(_ text: String, prompt: String, speechSeconds: Double) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return false }
        if speechSeconds < 1.5, stockPhrases.contains(lower) { return true }
        // Echoing the glossary prompt back.
        if !prompt.isEmpty, lower.count > 24, prompt.lowercased().contains(lower) { return true }
        if lower.hasPrefix("we were talking about"), prompt.lowercased().hasPrefix(String(lower.prefix(40))) { return true }
        return false
    }
}
