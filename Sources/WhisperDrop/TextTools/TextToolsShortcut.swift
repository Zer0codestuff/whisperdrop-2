import Carbon
import Foundation

/// Carbon registers a global shortcut without another Accessibility event tap.
@MainActor
final class TextToolsShortcut {
    private(set) var error: String?
    private var onInvoke: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x5744_5454

    func start(choice: String, onInvoke: @escaping () -> Void) {
        stop()
        self.onInvoke = onInvoke
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == TextToolsShortcut.signature, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcut = Unmanaged<TextToolsShortcut>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onInvoke?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            error = "The text shortcut could not be registered."
            return
        }
        let key: UInt32
        let modifiers: UInt32
        switch choice {
        case "command-shift-d": key = UInt32(kVK_ANSI_D); modifiers = UInt32(cmdKey | shiftKey)
        case "control-option-space": key = UInt32(kVK_Space); modifiers = UInt32(controlKey | optionKey)
        default: key = UInt32(kVK_ANSI_D); modifiers = UInt32(controlKey | optionKey)
        }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(key, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        error = registered == noErr ? nil : "This shortcut is in use. Choose another one in Settings, Writing."
        if registered != noErr, let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        onInvoke = nil
        error = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
