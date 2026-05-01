// HotkeyRegistrar.swift - Carbon-based global hotkey registration.
//
// Carbon's RegisterEventHotKey is the lightest path on macOS for a system-wide
// hotkey that fires from a non-frontmost app. The Swift API is uglier than
// e.g. KeyboardShortcuts SPM, but adds zero dependencies and is rock solid.
//
// Usage:
//
//   HotkeyRegistrar.shared.register(
//     keyCode: kVK_ANSI_A, modifiers: [.command, .shift],
//     onTrigger: { /* fired on key down */ }
//   )

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class HotkeyRegistrar {

    static let shared = HotkeyRegistrar()

    struct ModifierSet: OptionSet {
        let rawValue: UInt32
        static let command = ModifierSet(rawValue: UInt32(cmdKey))
        static let shift   = ModifierSet(rawValue: UInt32(shiftKey))
        static let option  = ModifierSet(rawValue: UInt32(optionKey))
        static let control = ModifierSet(rawValue: UInt32(controlKey))
    }

    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    private var nextId: UInt32 = 1
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerInstalled = false

    /// Register a global hotkey. Returns the id used to unregister; nil on
    /// failure (most likely cause: another app already holds this combo).
    @discardableResult
    func register(
        keyCode: Int,
        modifiers: ModifierSet,
        onTrigger: @escaping () -> Void
    ) -> UInt32? {
        installEventHandlerIfNeeded()

        let id = nextId
        nextId += 1
        var hotKeyId = EventHotKeyID(signature: fourCharCode("FL42"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers.rawValue,
            hotKeyId,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return nil
        }
        registrations[id] = Registration(id: id, ref: ref, handler: onTrigger)
        _ = hotKeyId  // silence unused-but-modified
        return id
    }

    func unregister(_ id: UInt32) {
        guard let reg = registrations[id] else { return }
        UnregisterEventHotKey(reg.ref)
        registrations.removeValue(forKey: id)
    }

    fileprivate func dispatch(id: UInt32) {
        registrations[id]?.handler()
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyCallback,
            1,
            &spec,
            nil,
            nil
        )
    }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    var code: FourCharCode = 0
    for ch in s.utf8.prefix(4) {
        code = (code << 8) + FourCharCode(ch)
    }
    return code
}

private let hotkeyCallback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
    guard let eventRef else { return noErr }
    var hkID = EventHotKeyID()
    let result = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    guard result == noErr else { return result }
    let id = hkID.id
    DispatchQueue.main.async {
        HotkeyRegistrar.shared.dispatch(id: id)
    }
    return noErr
}
