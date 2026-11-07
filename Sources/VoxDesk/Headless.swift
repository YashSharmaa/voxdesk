// `VoxDesk --transcribe <file>...`: the app's own pipeline (energy gate, Silero VAD, glossary prompt, model)
// on audio files, with timings. Never touches the microphone, the speakers or the clipboard.
import Darwin
import Foundation
import WhisperKit

enum Headless {
    static let usage = """
    Usage: VoxDesk --transcribe <file.wav|m4a|...> [more files]
             [--engine parakeet|whisper]   default: the app's setting (Fast English, Parakeet)
             [--model <id>]   Whisper checkpoint [--language auto|en|hi|hinglish] [--vocab "<comma list>"] [--no-vocab]
             [--repeat <n>]   transcribe each file n times (the first warm run and the rest)
             [--stream]       replay each file in real time with ~1 s partial passes, as the app does
                              while you speak, then report the time from the end of the audio to the final text
             [--json]
    Models: \(ModelChoice.all.map(\.id).joined(separator: ", "))
    """

    static func run(_ args: [String]) async -> Int32 {
        var files: [String] = []
        var engineChoice = Settings.engine
        var model = Settings.model
        var language = Settings.language.code
        var vocab = Settings.vocabulary
        var repeats = 1
        var stream = false
        var json = false
        var extra = Settings.language.stylePrompt
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--transcribe": break
            case "--engine":
                let v = next() ?? ""
                guard let e = EngineChoice(rawValue: v), EngineChoice.available.contains(e) else {
                    FileHandle.standardError.write(Data("Unknown or unavailable engine \(v). Available: \(EngineChoice.available.map(\.rawValue).joined(separator: ", "))\n".utf8))
                    return 2
                }
                engineChoice = e
            case "--model": model = next() ?? model
            case "--language":
                let v = next() ?? "auto"
                if v == "hinglish" {
                    language = LanguageChoice.hinglish.code
                    extra = LanguageChoice.hinglish.stylePrompt
                } else {
                    language = (v == "auto") ? nil : v
                }
            case "--vocab": vocab = next() ?? vocab
            case "--no-vocab": vocab = ""
            case "--extra-prompt": extra = next() ?? ""
            case "--repeat": repeats = max(1, Int(next() ?? "1") ?? 1)
            case "--stream": stream = true
            case "--json": json = true
            case "-h", "--help": print(usage); return 0
            default:
                if a.hasPrefix("--") { FileHandle.standardError.write(Data("Unknown option \(a)\n\(usage)\n".utf8)); return 2 }
                files.append(a)
            }
            i += 1
        }
        guard !files.isEmpty else { print(usage); return 2 }

        @Sendable func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

        let engine = SpeechEngine.shared
        let modelName = engineChoice == .parakeet ? "parakeet-tdt-0.6b-v2" : model
        let lastPct = Locked(-1)
        await engine.onPhase { phase in
            switch phase {
            case .downloading(let f):
                let pct = Int(f * 10) * 10
                if lastPct.swap(pct) != pct { log("downloading \(modelName): \(pct)%") }
            case .optimising: log("optimising \(modelName) for this Mac (first run)…")
            default: break
            }
        }
        let report: LoadReport
        do {
            report = try await engine.load(engine: engineChoice, model: model, vocabulary: vocab)
        } catch {
            log("error: \(error.localizedDescription)")
            return 1
        }
        log(String(format: "[load] model %@ | %@ | download %.2fs | prewarm %.2fs | load %.2fs | warm-up %.2fs | vad %.2fs | total %.2fs",
                   report.model, report.wasCold ? "cold (downloaded or specialised now)" : "warm (Core ML cache hit)",
                   report.downloadSeconds, report.prewarmSeconds, report.loadSeconds, report.warmupSeconds,
                   report.vadLoadSeconds, report.total))

        var options = PipelineOptions(language: language, vocabulary: vocab)
        options.extraPrompt = extra
        var outputs: [[String: Any]] = []
        for file in files {
            let samples: [Float]
            do {
                samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: file)
            } catch {
                log("error: \(file): \(error.localizedDescription)")
                return 1
            }
            for run in 1...repeats {
                do {
                    var r: PipelineResult
                    var afterEnd: Double? = nil
                    var partials: [Double] = []
                    if stream {
                        (r, afterEnd, partials) = try await replay(samples, options: options)
                    } else {
                        r = try await engine.transcribe(samples, options: options)
                    }
                    print(r.text)
                    var line = String(format: "[timing] %@ run %d | audio %.2fs | speech %.2fs (max p %.2f) | vad %.0f ms | whisper %.0f ms (encode %.0f, decode %.0f, %d prompt + %d tokens, %d fallbacks) | pipeline %.0f ms | lang %@",
                                      (file as NSString).lastPathComponent, run, r.audioSeconds, r.speechSeconds, r.maxSpeechProb,
                                      r.vadSeconds * 1000, r.whisperSeconds * 1000, r.encodeSeconds * 1000, r.decodeSeconds * 1000,
                                      r.promptTokens, r.tokens, r.fallbacks, r.totalSeconds * 1000, r.language ?? "-")
                    if engineChoice == .parakeet {
                        line = String(format: "[timing] %@ run %d | audio %.2fs | speech %.2fs (max p %.2f) | vad %.0f ms | parakeet %.0f ms | boost %.0f ms%@ | pipeline %.0f ms",
                                      (file as NSString).lastPathComponent, run, r.audioSeconds, r.speechSeconds, r.maxSpeechProb,
                                      r.vadSeconds * 1000, r.whisperSeconds * 1000, r.boostSeconds * 1000,
                                      r.boosted.isEmpty ? "" : " (wrote \(r.boosted.joined(separator: ", ")))", r.totalSeconds * 1000)
                    }
                    if let reason = r.skipped { line += " | skipped: \(reason)" }
                    if let afterEnd {
                        line += String(format: " | %d previews (mean %.0f ms) | end of audio to text %.0f ms",
                                       partials.count, partials.isEmpty ? 0 : partials.reduce(0, +) / Double(partials.count) * 1000, afterEnd * 1000)
                    }
                    log(line)
                    outputs.append(["file": file, "run": run, "text": r.text, "audio_s": r.audioSeconds,
                                    "pipeline_ms": r.totalSeconds * 1000, "whisper_ms": r.whisperSeconds * 1000,
                                    "vad_ms": r.vadSeconds * 1000, "language": r.language ?? "",
                                    "skipped": r.skipped ?? "", "after_end_ms": (afterEnd ?? -1) * 1000])
                } catch {
                    log("error: \(file): \(error.localizedDescription)")
                    return 1
                }
            }
        }
        let mem = memory()
        log(String(format: "[memory] peak footprint %.0f MB | peak RSS %.0f MB", mem.footprintMB, mem.rssMB))
        if json, let data = try? JSONSerialization.data(withJSONObject: ["results": outputs, "load_s": report.total,
                                                                         "peak_footprint_mb": mem.footprintMB], options: [.prettyPrinted]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return 0
    }

    /// Plays the file into the pipeline at real-time speed, as the app does while you speak: a preview pass on
    /// the audio so far about every second (never two at once, confirming text as it settles), then the final
    /// pass over the unconfirmed tail once the audio has ended, as on key-up.
    static func replay(_ samples: [Float], options: PipelineOptions) async throws -> (PipelineResult, Double, [Double]) {
        let stream = DictationStream(options: options)
        let duration = Double(samples.count) / 16000
        let start = Date()
        let previews = Task {
            while !Task.isCancelled {
                let passStart = Date()
                let available = min(samples.count, Int(passStart.timeIntervalSince(start) * 16000))
                _ = await stream.step(Array(samples[0..<available]))
                let wait = 1.0 - Date().timeIntervalSince(passStart)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
        try await Task.sleep(for: .seconds(duration))
        previews.cancel()
        let endOfAudio = Date()
        let r = try await stream.finish(samples)
        let after = Date().timeIntervalSince(endOfAudio)
        let committedSeconds = Double(await stream.committedEnd) / 16000
        let commits = await stream.commitSeconds
        FileHandle.standardError.write(Data(String(format: "[stream] %d commits (mean %.0f ms) covered %.2fs of %.2fs before the end; final pass covered %.2fs\n",
                                                   commits.count, commits.isEmpty ? 0 : commits.reduce(0, +) / Double(commits.count) * 1000,
                                                   committedSeconds, duration, duration - committedSeconds).utf8))
        return (r, after, await stream.previewSeconds)
    }

    final class Locked<T>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()
        init(_ v: T) { value = v }
        func swap(_ v: T) -> T { lock.withLock { let old = value; value = v; return old } }
    }

    static func memory() -> (footprintMB: Double, rssMB: Double) {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let footprint = ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : 0
        return (footprint, Double(usage.ru_maxrss) / 1_048_576)   // ru_maxrss is in bytes on macOS
    }
}
