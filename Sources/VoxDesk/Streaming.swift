// Live transcription while the user speaks. About once a second one of two things happens:
// - if the speaker paused (400 ms or more of quiet, at least 2 s after the last commit), the audio up to the
//   middle of that pause is transcribed at full quality and committed, and never decoded again;
// - otherwise the open stretch since the last commit gets a quick preview pass for the overlay.
// On release only the uncommitted tail is transcribed, so the wait after speaking stays short however long
// the dictation was. Whisper's own segment timestamps proved too unstable to confirm text on, so pauses are
// found from the signal itself.
import Foundation

actor DictationStream {
    private let options: PipelineOptions
    private(set) var committed: [String] = []
    private(set) var committedEnd = 0                 // samples
    private var inFlight: Task<String?, Never>?
    private var inFlightIsPreview = false
    private var abort: AbortFlag?
    private(set) var previewSeconds: [Double] = []
    private(set) var commitSeconds: [Double] = []

    static let debug = ProcessInfo.processInfo.environment["VOXDESK_DEBUG"] != nil
    static let frame = 320                            // 20 ms
    static let minPauseFrames = 20                    // 400 ms: shorter pauses are usually commas
    static let minChunk = 2 * 16000

    init(options: PipelineOptions) {
        self.options = options
    }

    /// One background step over everything recorded so far. Returns the text to show, or nil.
    func step(_ samples: [Float]) async -> String? {
        if let cut = Self.findCut(samples, after: committedEnd) {
            let task = Task { await self.commit(samples, upTo: cut) }
            inFlight = task
            inFlightIsPreview = false
            return await task.value
        }
        guard samples.count - committedEnd >= 16000 else { return nil }
        let flag = AbortFlag()
        abort = flag
        let task = Task { await self.preview(samples, abort: flag) }
        inFlight = task
        inFlightIsPreview = true
        return await task.value
    }

    private func commit(_ samples: [Float], upTo cut: Int) async -> String? {
        let started = Date()
        let chunk = Array(samples[committedEnd..<cut])
        guard let r = try? await SpeechEngine.shared.transcribe(chunk, options: options) else { return nil }
        commitSeconds.append(Date().timeIntervalSince(started))
        if Self.debug {
            FileHandle.standardError.write(Data(String(format: "[commit %.2f-%.2fs in %.0f ms] %@\n",
                Double(committedEnd) / 16000, Double(cut) / 16000, Date().timeIntervalSince(started) * 1000, r.text).utf8))
        }
        if !r.text.isEmpty { committed.append(r.text) }
        committedEnd = cut
        return Self.join(committed)
    }

    private func preview(_ samples: [Float], abort flag: AbortFlag) async -> String? {
        let started = Date()
        var opts = options
        opts.partial = true
        guard let r = try? await SpeechEngine.shared.transcribe(Array(samples[committedEnd...]), options: opts, abort: flag),
              r.skipped != "aborted", !flag.isSet else { return nil }
        previewSeconds.append(Date().timeIntervalSince(started))
        return Self.join(committed + [r.text])
    }

    /// Stops a preview pass (a commit pass is allowed to finish) and transcribes the uncommitted tail.
    /// The result's text is the whole dictation.
    func finish(_ samples: [Float]) async throws -> PipelineResult {
        if inFlightIsPreview {
            // The flag ends decoding; cancellation also stops it during the prompt prefill.
            abort?.set()
            inFlight?.cancel()
        }
        _ = await inFlight?.value
        let tailStart = min(committedEnd, samples.count)
        var r = try await SpeechEngine.shared.transcribe(Array(samples[tailStart...]), options: options)
        if !committed.isEmpty {
            r.text = Self.join(committed + [r.text])
            r.skipped = nil
        }
        r.audioSeconds = Double(samples.count) / 16000
        return r
    }

    /// The middle of the latest pause of 400 ms or more that starts at least 2 s after `start` and that speech
    /// has resumed after (or that has lasted 800 ms). Quiet is judged against this recording's own levels.
    static func findCut(_ samples: [Float], after start: Int) -> Int? {
        let n = (samples.count - start) / frame
        guard samples.count - start >= minChunk + minPauseFrames * frame, n > 0 else { return nil }
        var db = [Float](repeating: -120, count: n)
        samples.withUnsafeBufferPointer { buf in
            for f in 0..<n {
                var sum: Float = 0
                let base = start + f * frame
                for j in 0..<frame { let x = buf[base + j]; sum += x * x }
                db[f] = 10 * log10(max(sum / Float(frame), 1e-12))
            }
        }
        let sorted = db.sorted()
        let floor = sorted[n / 10], peak = sorted[min(n - 1, n * 9 / 10)]
        guard peak - floor > 12 else { return nil }   // no clear speech-versus-quiet contrast yet
        let threshold = max(floor + 6, peak - 25)
        var best: Int?
        var runStart: Int?
        for f in 0...n {
            let quiet = f < n && db[f] < threshold
            if quiet {
                if runStart == nil { runStart = f }
                continue
            }
            if let s = runStart {
                let length = f - s
                let resumed = f < n
                if length >= minPauseFrames, s * frame >= minChunk, resumed || length >= 2 * minPauseFrames {
                    best = start + (s + length / 2) * frame
                }
            }
            runStart = nil
        }
        return best
    }

    static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            var part = raw.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if !out.isEmpty {
                // A chunk cut at a pause mid-sentence starts with a capital Whisper invented; lower it unless the
                // previous chunk ended a sentence or the word is "I" or looks like a name or acronym.
                if let last = out.last, !".?!।".contains(last),
                   let firstWord = part.split(separator: " ").first,
                   firstWord != "I", !firstWord.hasPrefix("I'"),
                   firstWord.count > 1, firstWord.dropFirst().allSatisfy({ $0.isLowercase || !$0.isLetter }) {
                    part = part.prefix(1).lowercased() + part.dropFirst()
                }
                out += " "
            }
            out += part
        }
        return out
    }
}
