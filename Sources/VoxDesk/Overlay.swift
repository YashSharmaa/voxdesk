// The floating overlay near the bottom centre of the screen: a live waveform while listening, the partial
// transcript as it firms up, a brief "transcribing" state, then a fade. It is a non-activating borderless
// panel that ignores the mouse, so the terminal underneath keeps focus and receives the paste.
import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case hidden, listening, transcribing, done(String), message(String) }
    @Published var phase: Phase = .hidden
    @Published var partial = ""
    @Published var latched = false
    /// Smoothed input level, 0...1, read by the waveform every frame.
    var level: CGFloat = 0
    private var target: CGFloat = 0

    func push(rms: Float) {
        // -55 dBFS is the floor, -15 dBFS fills the wave.
        let db = 20 * log10(max(rms, 1e-7))
        target = CGFloat(min(max((db + 55) / 40, 0), 1))
    }

    /// Called once per frame by the waveform: quick attack, slower release, like a VU meter.
    func tick() -> CGFloat {
        let k: CGFloat = target > level ? 0.35 : 0.08
        level += (target - level) * k
        return level
    }

    func resetLevel() { level = 0; target = 0 }
}

final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private lazy var panel: OverlayPanel = {
        let p = OverlayPanel()
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }()
    private var hideTask: Task<Void, Never>?

    func show(_ phase: OverlayModel.Phase) {
        hideTask?.cancel()
        model.phase = phase
        if phase == .listening { model.partial = ""; model.resetLevel() }
        position()
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    /// Shows a final state briefly, then fades out.
    func finish(_ phase: OverlayModel.Phase, after delay: Double = 0.6) {
        model.phase = phase
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                if self.panel.alphaValue == 0 { self.panel.orderOut(nil); self.model.phase = .hidden }
            }
        })
    }

    private func position() {
        // The screen with the mouse on it, which is usually the one being typed on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 36))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    statusDot
                    Waveform(model: model, active: model.phase == .listening)
                        .frame(height: 34)
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(captionIsPartial ? 0.92 : 0.75))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: caption)
    }

    private var captionIsPartial: Bool { model.phase == .listening || model.phase == .transcribing }

    private var caption: String {
        switch model.phase {
        case .listening: return model.partial.isEmpty ? (model.latched ? "Listening. Press again to finish." : "Listening…") : model.partial
        case .transcribing: return model.partial.isEmpty ? "Transcribing…" : model.partial
        case .done(let s), .message(let s): return s
        case .hidden: return ""
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch model.phase {
        case .transcribing:
            ProgressView().controlSize(.small).tint(.white).frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 14)
        case .message:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow).frame(width: 14)
        default:
            Circle().fill(Color(red: 1, green: 0.32, blue: 0.36)).frame(width: 9, height: 9).frame(width: 14)
        }
    }
}

/// A Siri-like waveform: a few sine ribbons of different frequency and colour, pinched at the ends and
/// scaled by the live input level, drawn every display frame.
struct Waveform: View {
    @ObservedObject var model: OverlayModel
    var active: Bool

    private static let waves: [(freq: Double, speed: Double, amp: Double, color: Color)] = [
        (1.6, 2.2, 1.00, Color(red: 0.36, green: 0.78, blue: 1.00)),
        (2.3, -2.9, 0.75, Color(red: 0.71, green: 0.45, blue: 1.00)),
        (3.1, 3.6, 0.55, Color(red: 1.00, green: 0.42, blue: 0.62)),
        (1.1, -1.5, 0.45, Color(red: 0.40, green: 1.00, blue: 0.82)),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active && model.level < 0.002)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = active ? model.tick() : max(0, model.level * 0.9)
                if !active { model.level = level }
                let mid = size.height / 2
                // A thin resting line so the overlay never looks dead, plus the level on top.
                let amplitude = (0.06 + 0.94 * Double(level)) * Double(size.height) * 0.46
                ctx.blendMode = .plusLighter
                for wave in Self.waves {
                    var line = Path()
                    let steps = 90
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        // Pinch both ends with a smooth envelope.
                        let envelope = pow(sin(.pi * x), 2)
                        let y = sin(2 * .pi * wave.freq * x + t * wave.speed) * envelope * amplitude * wave.amp
                        let p = CGPoint(x: x * Double(size.width), y: Double(mid) + y)
                        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                    }
                    // A translucent body between the wave and the centre line, then the bright edge.
                    var body = line
                    body.addLine(to: CGPoint(x: size.width, y: mid))
                    body.addLine(to: CGPoint(x: 0, y: mid))
                    body.closeSubpath()
                    ctx.fill(body, with: .color(wave.color.opacity(0.22)))
                    ctx.stroke(line, with: .color(wave.color.opacity(0.9)), lineWidth: 1.8)
                }
            }
        }
    }
}
