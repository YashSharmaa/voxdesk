// `VoxDesk --self-test`: checks the logic that has no model in it, without touching the microphone, the
// speakers, the user's clipboard or the keyboard. The pasteboard round trip runs on a private pasteboard.
import AppKit
import SwiftUI

enum SelfTest {
    @MainActor
    static func run(renderOverlayTo path: String?) -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        // Trigger state machine: tap toggles, hold is push-to-talk.
        var m = TriggerStateMachine()
        check(m.keyDown(at: 0) == .start, "key-down starts")
        check(m.keyUp(at: 0.15) == .none && m.state == .latched, "release under 280 ms latches toggle mode")
        check(m.keyDown(at: 3) == .stop, "next press stops a latched recording")
        check(m.keyUp(at: 3.1) == .none && m.state == .idle, "its release is swallowed")
        check(m.keyDown(at: 5) == .start && m.keyDown(at: 5.05) == .none, "key repeat is ignored")
        check(m.keyUp(at: 5.6) == .stop && m.state == .idle, "release after 280 ms stops (push-to-talk)")
        check(m.keyDown(at: 7) == .start && m.keyUp(at: 7.28) == .stop, "release at exactly 280 ms is a hold")

        // Glossary prompt.
        check(Vocabulary.terms(from: "TypeScript, pnpm\nGitHub;; ,") == ["TypeScript", "pnpm", "GitHub"], "glossary splits on commas, lines and semicolons")
        check(Vocabulary.promptSentence(from: "pnpm, Postgres") == "We were talking about pnpm, Postgres.", "glossary becomes a sentence")
        check(Vocabulary.promptSentence(from: "  ") == "", "empty glossary sends no prompt")
        check(Vocabulary.applySpelling("Run PNPM and push to Github, not pnpmx.", terms: ["pnpm", "GitHub"])
              == "Run pnpm and push to GitHub, not pnpmx.", "glossary spelling fixes letter case, whole words only")

        // Joining committed chunks.
        check(DictationStream.join(["Run the tests,", "Then deploy."]) == "Run the tests, then deploy.", "mid-sentence chunk is lowered")
        check(DictationStream.join(["Done.", "Next one."]) == "Done. Next one.", "sentence chunk keeps its capital")
        check(DictationStream.join(["I pushed it and", "GitHub is green"]) == "I pushed it and GitHub is green", "names keep their capitals")
        check(DictationStream.join(["so", "I think"]) == "so I think", "\"I\" stays upper case")

        // Pause finder: 2.5 s of tone, 0.5 s of quiet, 1 s of tone.
        func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { 0.3 * sin(Float($0) * 0.12) } }
        let clip = tone(2.5) + [Float](repeating: 0.0005, count: 8000) + tone(1)
        if let cut = DictationStream.findCut(clip, after: 0) {
            check(abs(cut - 44000) < 1600, "pause found mid-gap (cut at \(String(format: "%.2f", Double(cut) / 16000)) s)")
        } else {
            check(false, "pause found")
        }
        check(DictationStream.findCut(tone(2.5) + [Float](repeating: 0.0005, count: 3200) + tone(1), after: 0) == nil, "a 200 ms gap is not a pause")
        check(DictationStream.findCut(tone(1) + [Float](repeating: 0.0005, count: 8000) + tone(1), after: 0) == nil, "no cut in the first 2 s")

        // Hallucination filter and cleanup.
        check(SpeechEngine.isLikelyHallucination("Thank you.", prompt: "", speechSeconds: 0.5), "stock phrase on little speech is dropped")
        check(!SpeechEngine.isLikelyHallucination("Thank you.", prompt: "", speechSeconds: 2.0), "stock phrase with real speech is kept")
        let prompt = Vocabulary.promptSentence(from: Settings.defaultVocabulary)
        check(SpeechEngine.isLikelyHallucination(String(prompt.prefix(60)), prompt: prompt, speechSeconds: 3), "prompt echo is dropped")
        check(SpeechEngine.clean("  Hello <|endoftext|> world  ") == "Hello world", "special tokens and spaces are cleaned")
        check(SpeechEngine.peakFrameDBFS([Float](repeating: 0, count: 16000)) < SpeechEngine.silenceDBFS, "digital silence is below the energy gate")

        // Pasteboard snapshot and restore, on a private pasteboard.
        let pb = NSPasteboard(name: NSPasteboard.Name("dev.voxdesk.selftest.\(getpid())"))
        pb.clearContents()
        let a = NSPasteboardItem(); a.setString("first", forType: .string); a.setData(Data([1, 2, 3]), forType: .init("dev.voxdesk.raw"))
        let b = NSPasteboardItem(); b.setString("second", forType: .string)
        pb.writeObjects([a, b])
        let saved = Paster.snapshot(pb)
        pb.clearContents(); pb.setString("dictated", forType: .string)
        Paster.restore(saved, to: pb)
        let items = pb.pasteboardItems ?? []
        check(items.count == 2 && items[0].string(forType: .string) == "first" && items[1].string(forType: .string) == "second"
              && items[0].data(forType: .init("dev.voxdesk.raw")) == Data([1, 2, 3]), "pasteboard items and types are restored")
        pb.releaseGlobally()

        // Overlay panel never takes focus.
        let panel = OverlayPanel()
        check(!panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel) && panel.ignoresMouseEvents,
              "overlay panel is non-activating and click-through")

        if let path {
            let model = OverlayModel()
            model.phase = .listening
            model.partial = "Run pnpm install, then push the TypeScript fix to GitHub"
            model.level = 0.7
            let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: 420, height: 120).background(Color.gray.opacity(0.4)))
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
        }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
