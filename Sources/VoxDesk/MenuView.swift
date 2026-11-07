// The menu bar dropdown and the settings window.
import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var app: AppController
    var body: some View {
        Image(nsImage: Logo.menuBarIcon(listening: app.status == .listening))
    }
}

struct StatusRow: View {
    @ObservedObject var app: AppController
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(app.statusText).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Spacer()
        }
        if case .downloading(let f) = app.status {
            ProgressView(value: f).controlSize(.small)
        }
        if case .optimising(let since) = app.status {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                    Text("First run only: Core ML is compiling the model for this Mac's Neural Engine. Usually 20 to 45 seconds. \(Int(ctx.date.timeIntervalSince(since))) s so far.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var color: Color {
        switch app.status {
        case .ready: return .green
        case .listening: return .red
        case .transcribing: return .orange
        case .failed: return .red
        default: return .yellow
        }
    }
}

struct MenuView: View {
    @ObservedObject var app: AppController
    @AppStorage(Settings.Key.engine) private var engine = EngineChoice.defaultChoice.rawValue
    @AppStorage(Settings.Key.model) private var model = ModelChoice.defaultID
    @AppStorage(Settings.Key.language) private var language = LanguageChoice.auto.rawValue
    @AppStorage(Settings.Key.trigger) private var trigger = TriggerMode.shortcut.rawValue
    @AppStorage(Settings.Key.keepInClipboard) private var keep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: Logo.appIcon(size: 28)).resizable().frame(width: 22, height: 22)
                Text("VoxDesk").font(.headline)
                Spacer()
            }
            StatusRow(app: app)

            if !app.micAuthorised || !app.accessibilityTrusted {
                PermissionRows(app: app)
            }

            Divider()
            Picker("Trigger", selection: $trigger) {
                ForEach(TriggerMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: trigger) { _, _ in app.triggerChanged() }
            if trigger == TriggerMode.shortcut.rawValue {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .dictate)
                }
            }
            Text("Tap to start and tap again to finish, or hold to talk and release to paste.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if EngineChoice.available.count > 1 {
                Picker("Engine", selection: $engine) {
                    ForEach(EngineChoice.available) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: engine) { _, _ in app.engineChanged() }
            }
            if engine == EngineChoice.whisper.rawValue || EngineChoice.available.count == 1 {
                Picker("Language", selection: $language) {
                    ForEach(LanguageChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Model", selection: $model) {
                    ForEach(ModelChoice.all) { Text($0.label).tag($0.id) }
                }
                .onChange(of: model) { _, _ in app.modelChanged() }
            }
            Toggle("Keep text on the clipboard", isOn: $keep)
            Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))

            if !app.lastText.isEmpty {
                Divider()
                Text("Last: \(app.lastText)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            Text(Credits.short).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Vocabulary and settings…") { SettingsWindow.show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct PermissionRows: View {
    @ObservedObject var app: AppController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(ok: app.micAuthorised, title: "Microphone",
                detail: "To hear you while you hold or tap the shortcut.", action: "Allow…") { app.requestMicrophone() }
            row(ok: app.accessibilityTrusted, title: "Accessibility",
                detail: "To paste with Cmd+V into the app you are typing in, and for the Right Option trigger.",
                action: "Open Settings…") { app.requestAccessibility() }
        }
    }

    private func row(ok: Bool, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { Button(action, action: perform).controlSize(.small) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppController
    @AppStorage(Settings.Key.vocabulary) private var vocabulary = Settings.defaultVocabulary
    @AppStorage(Settings.Key.engine) private var engine = EngineChoice.defaultChoice.rawValue
    @AppStorage(Settings.Key.model) private var model = ModelChoice.defaultID
    @AppStorage(Settings.Key.language) private var language = LanguageChoice.auto.rawValue
    @AppStorage(Settings.Key.encoderOnGPU) private var encoderOnGPU = true

    var body: some View {
        Form {
            Section("Setup") {
                StatusRow(app: app)
                PermissionRows(app: app)
            }
            Section {
                TextEditor(text: $vocabulary)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 110)
                HStack {
                    Text(engine == EngineChoice.parakeet.rawValue
                         ? "Fast English boosts these words where the audio matches them."
                         : "Sent to Whisper as: “\(Vocabulary.promptSentence(from: vocabulary).prefix(140))…”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Reset") { vocabulary = Settings.defaultVocabulary }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Words you say often, separated by commas. Fast English swaps a misheard word for one of these when the audio supports it; Whisper reads them as the sentence before your dictation. Keep it under about 150 words.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech") {
                if EngineChoice.available.count > 1 {
                    Picker("Engine", selection: $engine) {
                        ForEach(EngineChoice.available) { Text($0.label).tag($0.rawValue) }
                    }
                    .onChange(of: engine) { _, _ in app.engineChanged() }
                    Text(EngineChoice(rawValue: engine)?.detail ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $language) {
                    ForEach(LanguageChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Model", selection: $model) {
                    ForEach(ModelChoice.all) { Text("\($0.label): \($0.detail)").tag($0.id) }
                }
                .onChange(of: model) { _, _ in app.modelChanged() }
                Toggle("Faster encoder on the GPU", isOn: $encoderOnGPU)
                    .onChange(of: encoderOnGPU) { _, _ in app.computeChanged() }
                Text("About 370 ms quicker per pass on Apple silicon, for about 2 GB more disk and 300 MB more memory. Off runs it on the Neural Engine.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Language, model and encoder apply to Multilingual (Whisper). Everything runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("VoxDesk \(VoxDeskVersion.string), MIT licensed.").font(.caption)
                Text(Credits.full).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Dictate", name: .dictate)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onDisappear { Settings.defaults.set(true, forKey: Settings.Key.onboarded) }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "VoxDesk"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(app: AppController.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
