// VoxDesk: local dictation for the Mac. Hold or tap a shortcut, speak, and the text is pasted where you are
// typing. Speech never leaves the machine. MIT licensed.
import AppKit
import SwiftUI

struct VoxDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run outside the bundle (LSUIElement covers the .app).
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppController.shared.launch() }
    }
}

enum VoxDeskVersion {
    static let string = "1.0.0"
}

enum Credits {
    static let short = "Fast English: Parakeet TDT 0.6B v2 by NVIDIA (CC-BY-4.0) via FluidAudio. Multilingual: Whisper by OpenAI via WhisperKit."
    static let full = """
    Fast English uses NVIDIA's Parakeet TDT 0.6B v2 and Parakeet CTC 110M (CC-BY-4.0), in FluidInference's Core ML \
    builds, through FluidAudio (Apache-2.0). Multilingual uses OpenAI's Whisper large-v3-turbo (MIT) through \
    Argmax's WhisperKit (MIT). Voice activity: Silero VAD (MIT). Shortcuts: KeyboardShortcuts by Sindre Sorhus (MIT).
    """
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") || arguments.contains("-v") {
    print(VoxDeskVersion.string)
    exit(0)
} else if arguments.contains("--help") || arguments.contains("-h") {
    print("VoxDesk \(VoxDeskVersion.string): local dictation for the Mac menu bar. Run without arguments to start the app.\n")
    print(Headless.usage)
    print("       VoxDesk --self-test\n       VoxDesk --version")
    exit(0)
} else if arguments.contains("--self-test") {
    Settings.register()
    _ = NSApplication.shared
    let render = arguments.firstIndex(of: "--render-overlay").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    exit(MainActor.assumeIsolated { SelfTest.run(renderOverlayTo: render) })
} else if arguments.contains("--transcribe") {
    Settings.register()
    Task {
        let code = await Headless.run(arguments)
        exit(code)
    }
    dispatchMain()
} else {
    VoxDeskApp.main()
}
