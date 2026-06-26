import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's RegisterEventHotKey. Fires even when the
/// app isn't focused, and — unlike NSEvent global monitors or CGEventTap —
/// needs NO Accessibility permission. Default binding: Control-Option-Space.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    /// keyCode/modifiers use Carbon constants (e.g. kVK_Space, controlKey).
    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.callback() }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x49565943) /* 'IVYC' */, id: 1)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else { return nil }
    }

    /// Control-Option-Space — push-to-talk from anywhere.
    static func controlOptionSpace(_ callback: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_Space),
                     modifiers: UInt32(controlKey | optionKey),
                     callback: callback)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
