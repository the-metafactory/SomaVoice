import AppKit
import ApplicationServices

/// Modifier-only hold-to-talk: hold Control+Option (exactly, nothing else) to
/// start listening; release either to send. Carbon RegisterEventHotKey can't
/// bind bare modifiers, so this watches `flagsChanged` via NSEvent monitors.
///
/// The GLOBAL monitor (events from other apps) requires Accessibility permission
/// — `requestAccessibility()` prompts for it. The LOCAL monitor works whenever
/// the app is focused even without it.
final class ModifierHotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var active = false
    private let onStart: () -> Void
    private let onStop: () -> Void

    /// The exact chord — Control+Option and no other modifier.
    private static let chord: NSEvent.ModifierFlags = [.control, .option]
    private static let watched: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
        let handle: (NSEvent) -> Void = { [weak self] e in self?.handle(e.modifierFlags) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { handle($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { handle($0); return $0 }
    }

    private func handle(_ flags: NSEvent.ModifierFlags) {
        let chordDown = flags.intersection(Self.watched) == Self.chord
        if chordDown, !active { active = true; onStart() }
        else if !chordDown, active { active = false; onStop() }
    }

    /// Prompt for Accessibility if not yet trusted (needed for the global monitor).
    @discardableResult
    static func requestAccessibility() -> Bool {
        let opt = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }
}
