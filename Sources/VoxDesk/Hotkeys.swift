// One trigger, two behaviours. Recording starts on key-down. A release within 280 ms was a tap and latches
// toggle mode (the next press stops); a longer hold is push-to-talk and stops on release.
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", initial: .init(.space, modifiers: [.option]))
}

struct TriggerStateMachine {
    enum State: Equatable { case idle, held(since: TimeInterval), latched, stopping }
    enum Action: Equatable { case none, start, stop }

    static let tapThreshold: TimeInterval = 0.280
    private(set) var state: State = .idle

    mutating func keyDown(at t: TimeInterval) -> Action {
        switch state {
        case .idle:
            state = .held(since: t)
            return .start
        case .latched:
            state = .stopping          // swallow the matching key-up
            return .stop
        case .held, .stopping:
            return .none               // key repeat
        }
    }

    mutating func keyUp(at t: TimeInterval) -> Action {
        switch state {
        case .held(let since):
            if t - since < Self.tapThreshold {
                state = .latched
                return .none
            }
            state = .idle
            return .stop
        case .stopping:
            state = .idle
            return .none
        case .idle, .latched:
            return .none
        }
    }

    /// Recording ended some other way (cancelled, too long, failed).
    mutating func reset() { state = .idle }
}

@MainActor
final class HotkeyController {
    private var machine = TriggerStateMachine()
    private var flagsMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var rightOptionDown = false

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    /// The trigger turned out to be part of another shortcut (Right Option + a key): throw the audio away.
    var onCancel: () -> Void = {}
    var onLatch: () -> Void = {}

    func install() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self, Settings.trigger == .shortcut else { return }
            self.handle(self.machine.keyDown(at: ProcessInfo.processInfo.systemUptime))
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self, Settings.trigger == .shortcut else { return }
            self.handle(self.machine.keyUp(at: ProcessInfo.processInfo.systemUptime))
            if self.machine.state == .latched { self.onLatch() }
        }
        applyTrigger()
    }

    /// Switches between the shortcut and the Right Option monitor.
    func applyTrigger() {
        for m in flagsMonitors + keyMonitors { NSEvent.removeMonitor(m) }
        flagsMonitors = []
        keyMonitors = []
        if Settings.trigger == .rightOption {
            KeyboardShortcuts.disable(.dictate)
            // Global monitors see other apps' events (needs Accessibility); local ones see ours.
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
                MainActor.assumeIsolated { self?.flagsChanged(e) }
            }) { flagsMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
                MainActor.assumeIsolated { self?.flagsChanged(e) }
                return e
            }) { flagsMonitors.append(l) }
            if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.otherKeyPressed() }
            }) { keyMonitors.append(k) }
        } else {
            KeyboardShortcuts.enable(.dictate)
        }
    }

    func reset() { machine.reset() }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == 61 else {          // kVK_RightOption
            return
        }
        let down = event.modifierFlags.contains(.option)
        guard down != rightOptionDown else { return }
        rightOptionDown = down
        let t = ProcessInfo.processInfo.systemUptime
        handle(down ? machine.keyDown(at: t) : machine.keyUp(at: t))
        if !down, machine.state == .latched { onLatch() }
    }

    private func otherKeyPressed() {
        // Right Option held while typing a key is a character shortcut, not dictation.
        if rightOptionDown, case .held = machine.state {
            machine.reset()
            onCancel()
        }
    }

    private func handle(_ action: TriggerStateMachine.Action) {
        switch action {
        case .start: onStart()
        case .stop: onStop()
        case .none: break
        }
    }
}
