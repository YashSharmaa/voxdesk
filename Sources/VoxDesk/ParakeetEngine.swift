// The Fast English engine: NVIDIA's Parakeet TDT 0.6B v2 (CC-BY-4.0) on Core ML through FluidAudio
// (Apache-2.0). One encoder pass over at most 15 s of audio plus a token-and-duration decoder, so a whole
// dictation is transcribed in a fraction of a Whisper pass. The glossary is applied as keyword boosting:
// a small CTC model (Parakeet CTC 110M, CC-BY-4.0) spots the listed terms in the audio and the transcript's
// words are swapped for them only where the audio supports the term better.
// Built only with Swift 6.2 or later (see Package@swift-6.2.swift).
#if canImport(FluidAudio)
import FluidAudio
import Foundation

final class ParakeetEngine: @unchecked Sendable {
    static let version: AsrModelVersion = .v2

    private var manager: AsrManager?
    private var ctcModels: CtcModels?
    private var boosting: VocabularyBoostingSession?
    private var boostingTerms: [String] = []

    var isLoaded: Bool { manager != nil }

    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    static var ctcDownloaded: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// Downloads (about 470 MB the first time, plus 100 MB for keyword boosting) and loads the models.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if manager != nil { return }
        let ctcMissing = !Self.ctcDownloaded
        let models = try await AsrModels.downloadAndLoad(version: Self.version, progressHandler: { p in
            progress(ctcMissing ? p.fractionCompleted * 0.83 : p.fractionCompleted)
        })
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        if ctcMissing { progress(0.85) }
        ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        ctcModels = nil
        boosting = nil
        boostingTerms = []
    }

    /// Builds the keyword-boosting session for this glossary, once per glossary.
    private func session(for terms: [String]) async -> VocabularyBoostingSession? {
        guard !terms.isEmpty, let ctcModels else { return nil }
        if terms == boostingTerms, let boosting { return boosting }
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        // FluidAudio's advice for dictation, where replacing a correctly heard word costs more than a miss.
        let thresholds = VocabularyBoostingSession.Thresholds(cbw: 0, minSimilarity: 0.7)
        boosting = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels, thresholds: thresholds)
        boostingTerms = terms
        return boosting
    }

    /// One pass over a second of silence, and one keyword-boosting pass, so the first dictation is fast.
    func warmUp(terms: [String]) async {
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await transcribe(silence, terms: terms)
        if let session = await session(for: terms) {
            let timing = TokenTiming(token: "▁warm", tokenId: 0, startTime: 0.2, endTime: 0.5, confidence: 1)
            _ = await session.rescore(text: "warm", tokenTimings: [timing], audioSamples: silence)
        }
    }

    struct Output {
        var text: String
        var asrSeconds: Double
        var boostSeconds: Double
        var replaced: [String]
    }

    /// Transcribes 16 kHz mono samples. `terms` empty skips keyword boosting (live previews do).
    func transcribe(_ samples: [Float], terms: [String]) async throws -> Output {
        guard let manager else { throw NSError(domain: "VoxDesk", code: 3, userInfo: [NSLocalizedDescriptionKey: "The model is not loaded yet."]) }
        var audio = samples
        // FluidAudio refuses anything under 0.3 s; pad a quick "yes" with silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16000)
        if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }

        let t0 = Date()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let asrSeconds = Date().timeIntervalSince(t0)
        var output = Output(text: result.text, asrSeconds: asrSeconds, boostSeconds: 0, replaced: [])

        let session = await session(for: terms)
        if let timings = result.tokenTimings, !timings.isEmpty, let session {
            let t1 = Date()
            if let rescored = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: audio),
               rescored.wasModified {
                output.text = rescored.text
                output.replaced = rescored.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
            }
            output.boostSeconds = Date().timeIntervalSince(t1)
        }
        return output
    }
}
#endif
