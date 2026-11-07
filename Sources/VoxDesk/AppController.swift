// Ties it together: hotkey -> microphone -> overlay with live partials -> final transcription -> paste.
import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Status: Equatable {
        case starting, downloading(Double), optimising(since: Date), loading, ready, listening, transcribing, failed(String)
    }

    @Published var status: Status = .starting
    @Published var lastText = ""
    @Published var micAuthorised = false
    @Published var accessibilityTrusted = false
    @Published var launchAtLogin = false

    let overlay = OverlayController()
    private let capture = AudioCapture()
    private let hotkeys = HotkeyController()
    private var partialTask: Task<Void, Never>?
    private var stream: DictationStream?
    private var recordingStarted = Date()
    private var permissionTimer: Timer?

    var isListening: Bool { status == .listening }

    func launch() {
        Settings.register()
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        capture.onLevel = { [weak self] rms in
            Task { @MainActor in self?.overlay.model.push(rms: rms) }
        }
        hotkeys.onStart = { [weak self] in self?.startDictation() }
        hotkeys.onStop = { [weak self] in self?.finishDictation() }
        hotkeys.onCancel = { [weak self] in self?.cancelDictation() }
        // A tap under 280 ms latched toggle mode: the overlay says how to finish.
        hotkeys.onLatch = { [weak self] in self?.overlay.model.latched = true }
        hotkeys.install()

        Task {
            await SpeechEngine.shared.onPhase { phase in
                Task { @MainActor in AppController.shared.apply(phase) }
            }
            await loadModel()
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { await SpeechEngine.shared.warmUp() }
        }

        // Keep the permission rows honest while the user is in System Settings.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppController.shared.refreshPermissions() }
        }

        // VOXDESK_NO_WELCOME=1 skips the first-run window (for launching in the background from a script).
        let quiet = ProcessInfo.processInfo.environment["VOXDESK_NO_WELCOME"] != nil
        if !quiet, !Settings.defaults.bool(forKey: Settings.Key.onboarded) || !micAuthorised || !accessibilityTrusted {
            SettingsWindow.show()
        }
    }

    // MARK: Model

    func loadModel(force: Bool = false) async {
        do {
            let r = try await SpeechEngine.shared.load(engine: Settings.engine, model: Settings.model, force: force)
            NSLog("VoxDesk: model %@ ready, %@, download %.1fs, optimise %.1fs, load %.2fs, warm-up %.2fs",
                  r.model, r.alreadyLoaded ? "already loaded" : (r.wasCold ? "cold" : "warm"),
                  r.downloadSeconds, r.prewarmSeconds, r.loadSeconds, r.warmupSeconds)
        } catch {
            NSLog("VoxDesk: model failed to load: %@", error.localizedDescription)
            status = .failed(error.localizedDescription)
        }
    }

    func modelChanged() {
        Task { await loadModel() }
    }

    /// Switching engine unloads the other one, so only the selected engine holds memory and stays warm.
    func engineChanged() {
        Task { await loadModel() }
    }

    func computeChanged() {
        Task { await loadModel(force: true) }
    }

    private func apply(_ phase: EnginePhase) {
        if status == .listening || status == .transcribing { return }
        switch phase {
        case .idle: status = .starting
        case .downloading(let f): status = .downloading(f)
        case .optimising:
            if case .optimising = status {} else { status = .optimising(since: Date()) }
        case .loading: status = .loading
        case .ready: status = .ready
        case .failed(let message): status = .failed(message)
        }
    }

    var statusText: String {
        switch status {
        case .starting: return "Starting…"
        case .downloading(let f): return "Downloading model… \(Int(f * 100))%"
        case .optimising: return "Optimising model for this Mac…"
        case .loading: return "Loading model…"
        case .ready: return "Ready"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .failed(let m): return "Error: \(m)"
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        micAuthorised = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in AppController.shared.refreshPermissions() }
            }
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refreshPermissions()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("VoxDesk: launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func triggerChanged() { hotkeys.applyTrigger() }

    // MARK: Dictation

    func startDictation() {
        guard status != .listening, status != .transcribing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            hotkeys.reset()
            requestMicrophone()
            return
        default:
            hotkeys.reset()
            overlay.show(.message("Microphone access is off. Open VoxDesk settings to allow it."))
            overlay.finish(.message("Microphone access is off. Open VoxDesk settings to allow it."), after: 2.5)
            return
        }
        do {
            try capture.start()
        } catch {
            hotkeys.reset()
            overlay.show(.message(error.localizedDescription))
            overlay.finish(.message(error.localizedDescription), after: 2.5)
            return
        }
        recordingStarted = Date()
        status = .listening
        overlay.model.latched = false
        overlay.show(.listening)
        startPartials()
    }

    /// Live preview: about once a second, transcribe what has not been confirmed yet (see DictationStream).
    /// Passes never overlap; the next starts a second after the previous one started, or when it ends.
    private func startPartials() {
        partialTask?.cancel()
        let stream = DictationStream(options: .fromSettings())
        self.stream = stream
        partialTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.status == .listening {
                let passStart = Date()
                if await SpeechEngine.shared.isReady,
                   let text = await stream.step(self.capture.snapshot()),
                   !Task.isCancelled, self.status == .listening, !text.isEmpty {
                    self.overlay.model.partial = text
                }
                let wait = 1.0 - Date().timeIntervalSince(passStart)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
    }

    func finishDictation() {
        guard status == .listening else { return }
        let samples = capture.stop()
        partialTask?.cancel()
        status = .transcribing
        overlay.show(.transcribing)
        let keep = Settings.keepInClipboard
        Task { @MainActor in
            defer { self.hotkeys.reset() }
            guard await SpeechEngine.shared.isReady else {
                await self.settle()
                self.overlay.finish(.message("The model is still loading. Try again in a moment."), after: 2)
                return
            }
            do {
                let stream = self.stream ?? DictationStream(options: .fromSettings())
                self.stream = nil
                let result = try await stream.finish(samples)
                await self.settle()
                guard !result.text.isEmpty else {
                    self.overlay.finish(.message("No speech heard"), after: 0.8)
                    return
                }
                self.lastText = result.text
                let outcome = await Paster.insert(result.text, keep: keep)
                switch outcome {
                case .copiedOnly:
                    self.overlay.finish(.message("Copied. Allow Accessibility to paste automatically."), after: 2.5)
                default:
                    self.overlay.finish(.done(result.text), after: 0.7)
                }
            } catch {
                await self.settle()
                self.overlay.finish(.message(error.localizedDescription), after: 2)
            }
        }
    }

    func cancelDictation() {
        guard status == .listening else { return }
        capture.stop()
        partialTask?.cancel()
        stream = nil
        hotkeys.reset()
        overlay.hide()
        Task { await settle() }
    }

    /// After a dictation, show the engine's state again (it may have been loading a new model meanwhile).
    private func settle() async {
        status = .ready
        apply(await SpeechEngine.shared.phase)
    }
}
