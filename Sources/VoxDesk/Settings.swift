// User settings, stored in UserDefaults, plus the folders VoxDesk keeps its models in.
import Foundation

enum Paths {
    /// ~/Library/Application Support/VoxDesk. Everything VoxDesk downloads lives under here.
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("VoxDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The Hugging Face style cache WhisperKit downloads into: models/<org>/<repo>/<variant>.
    static var models: URL {
        let url = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var vad: URL {
        let url = support.appendingPathComponent("VAD", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A Whisper checkpoint the user can pick. All are Argmax's Core ML builds (MIT) of OpenAI's MIT weights.
struct ModelChoice: Identifiable, Hashable {
    let id: String      // folder name in argmaxinc/whisperkit-coreml
    let label: String
    let detail: String

    static let all: [ModelChoice] = [
        ModelChoice(id: "openai_whisper-large-v3-v20240930_626MB", label: "Large v3 Turbo",
                    detail: "626 MB, best accuracy, Hindi and Hinglish"),
        ModelChoice(id: "openai_whisper-large-v3-v20240930_547MB", label: "Large v3 Turbo (compact)",
                    detail: "547 MB, slightly lower accuracy"),
        ModelChoice(id: "openai_whisper-small_216MB", label: "Small",
                    detail: "216 MB, faster, weaker on jargon"),
        ModelChoice(id: "openai_whisper-base", label: "Base",
                    detail: "about 150 MB, fastest usable"),
    ]
    static let defaultID = all[0].id

    static func named(_ id: String) -> ModelChoice {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Which recogniser runs. Fast English is Parakeet (only built with Swift 6.2 or later); Multilingual is Whisper.
enum EngineChoice: String, CaseIterable, Identifiable {
    case parakeet, whisper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .parakeet: return "Fast English (Parakeet)"
        case .whisper: return "Multilingual (Whisper)"
        }
    }
    var detail: String {
        switch self {
        case .parakeet: return "English only, text in about a tenth of a second. 470 MB, plus 100 MB for vocabulary boosting."
        case .whisper: return "Hindi, Hinglish and 90 more languages; slower. 626 MB for Large v3 Turbo."
        }
    }

    static var available: [EngineChoice] {
        #if canImport(FluidAudio)
        return allCases
        #else
        return [.whisper]
        #endif
    }
    static var defaultChoice: EngineChoice { available[0] }
}

enum LanguageChoice: String, CaseIterable, Identifiable {
    case auto, english, hindi, hinglish
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .hindi: return "Hindi (Devanagari)"
        case .hinglish: return "Hinglish (Roman script)"
        }
    }
    /// Whisper language code, or nil to detect.
    var code: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .hindi, .hinglish: return "hi"
        }
    }

    /// Whisper writes Hindi in Devanagari; a romanised Hinglish sentence before the dictation makes it carry on
    /// in Roman script, with English words left in English.
    var stylePrompt: String {
        self == .hinglish ? "Haan bhai, main kal tak code push kar dunga, phir hum deploy karenge." : ""
    }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case shortcut, rightOption
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shortcut: return "Keyboard shortcut"
        case .rightOption: return "Hold Right Option"
        }
    }
}

enum Settings {
    static let defaults = UserDefaults.standard

    enum Key {
        static let engine = "engine"
        static let model = "model"
        static let language = "language"
        static let vocabulary = "vocabulary"
        static let keepInClipboard = "keepInClipboard"
        static let trigger = "trigger"
        static let onboarded = "onboarded"
        static let encoderOnGPU = "encoderOnGPU"
    }

    /// Every glossary token is fed through the decoder before each pass (about 5 ms each on an M5 Max), so the
    /// default list is kept to the terms Whisper most often gets wrong.
    static let defaultVocabulary = """
    TypeScript, JavaScript, Python, pnpm, npm, Postgres, GitHub, API, CLI, Docker, Telegram, iMessage, \
    OpenAI, Claude, JSON, README, localhost, Xcode
    """

    static var engine: EngineChoice {
        get {
            let e = EngineChoice(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? EngineChoice.defaultChoice
            return EngineChoice.available.contains(e) ? e : EngineChoice.defaultChoice
        }
        set { defaults.set(newValue.rawValue, forKey: Key.engine) }
    }
    static var model: String {
        get { defaults.string(forKey: Key.model) ?? ModelChoice.defaultID }
        set { defaults.set(newValue, forKey: Key.model) }
    }
    static var language: LanguageChoice {
        get { LanguageChoice(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }
    static var vocabulary: String {
        get { defaults.string(forKey: Key.vocabulary) ?? defaultVocabulary }
        set { defaults.set(newValue, forKey: Key.vocabulary) }
    }
    static var keepInClipboard: Bool {
        get { defaults.bool(forKey: Key.keepInClipboard) }
        set { defaults.set(newValue, forKey: Key.keepInClipboard) }
    }
    static var trigger: TriggerMode {
        get { TriggerMode(rawValue: defaults.string(forKey: Key.trigger) ?? "") ?? .shortcut }
        set { defaults.set(newValue.rawValue, forKey: Key.trigger) }
    }

    /// The encoder is about 4 times faster on the GPU, but Core ML's GPU build of it takes about 2.4 GB of disk
    /// (against 0.5 GB for the Neural Engine) and about 300 MB more memory.
    static var encoderOnGPU: Bool {
        get { defaults.bool(forKey: Key.encoderOnGPU) }
        set { defaults.set(newValue, forKey: Key.encoderOnGPU) }
    }

    static func register() {
        defaults.register(defaults: [
            Key.encoderOnGPU: true,
            Key.engine: EngineChoice.defaultChoice.rawValue,
            Key.model: ModelChoice.defaultID,
            Key.language: LanguageChoice.auto.rawValue,
            Key.vocabulary: defaultVocabulary,
            Key.keepInClipboard: false,
            Key.trigger: TriggerMode.shortcut.rawValue,
        ])
    }
}

/// Turns the glossary into a prior-sentence prompt. Whisper reads the prompt as the transcript of what came
/// before, not as instructions, so a natural sentence that uses the words works best.
enum Vocabulary {
    static func terms(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Writes glossary terms the way the glossary spells them where the transcript has the same word in other
    /// letter case ("PNPM" -> "pnpm", "Github" -> "GitHub"). Whole words only.
    static func applySpelling(_ text: String, terms: [String]) -> String {
        var out = text
        for term in terms where term.count > 1 {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return out
    }

    static func promptSentence(from text: String) -> String {
        let words = terms(from: text)
        guard !words.isEmpty else { return "" }
        return "We were talking about " + words.joined(separator: ", ") + "."
    }
}
