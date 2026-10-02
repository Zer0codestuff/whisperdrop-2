import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Contract file. Watches the chosen modifier key globally and reports press/release.
@MainActor
final class HotkeyMonitor {
    enum Event { case pressed, released, cancelled }
    /// Called on the main actor. `cancelled` means another key was combined with the hotkey while held.
    var onEvent: ((Event) -> Void)?
    /// Called on the main actor for a non-repeating Escape press, including during hands-free listening.
    var onEscape: (() -> Void)?
    var hotkey: HotkeyChoice = .fn {
        didSet {
            guard hotkey != oldValue, isRunning, !restarting else { return }
            restarting = true
            stop()
            _ = start()
            restarting = false
        }
    }
    /// True when the monitor is running.
    private(set) var isRunning = false
    /// True after `start()` returns false because Input Monitoring is not granted.
    private(set) var requiredPermissionMissing = false

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDown = false
    private var emittedPress = false
    private var restarting = false

    /// Starts monitoring. Returns false if Input Monitoring is missing or the tap cannot be created.
    /// Does not prompt; call `CGRequestListenEventAccess` from the UI after explaining why.
    @discardableResult func start() -> Bool {
        if isRunning { return true }
        guard CGPreflightListenEventAccess() else {
            requiredPermissionMissing = true
            return false
        }
        requiredPermissionMissing = false

        let info = Unmanaged.passUnretained(self).toOpaque()
        let full = Self.mask(.flagsChanged) | Self.mask(.keyDown) | Self.maskRaw(Self.systemDefinedRaw)
        let reduced = Self.mask(.flagsChanged) | Self.mask(.keyDown)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: full,
            callback: hotkeyTapCallback,
            userInfo: info
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: reduced,
            callback: hotkeyTapCallback,
            userInfo: info
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapPort = port
        runLoopSource = source
        keyDown = false
        emittedPress = false
        isRunning = true
        return true
    }

    func stop() {
        let cancel = emittedPress
        teardown()
        if cancel {
            onEvent?(.cancelled)
        }
    }

    deinit {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                teardown()
            }
        }
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let raw = type.rawValue
        if raw == CGEventType.tapDisabledByTimeout.rawValue || raw == CGEventType.tapDisabledByUserInput.rawValue {
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let spec = Self.spec(for: hotkey)
        if raw == CGEventType.flagsChanged.rawValue {
            let code = Self.keyCode(event)
            if code == spec.keyCode {
                let down = Self.edgeDown(spec, event: event, wasDown: keyDown)
                if down != keyDown {
                    keyDown = down
                    if down {
                        emittedPress = true
                        onEvent?(.pressed)
                    } else if emittedPress {
                        emittedPress = false
                        onEvent?(.released)
                    }
                }
            } else if keyDown, Self.otherModifierPressed(code: code, event: event) {
                cancelChord()
            }
        } else if raw == CGEventType.keyDown.rawValue {
            // Live text typed by dictation itself is not a shortcut chord.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  event.getIntegerValueField(.eventSourceUserData) != LiveTextWriter.eventMarker else {
                return Unmanaged.passUnretained(event)
            }
            let code = Self.keyCode(event)
            if code == CGKeyCode(kVK_Escape) {
                onEscape?()
            }
            if code != spec.keyCode, keyDown || Self.hotkeyDown(spec, event: event) {
                if !keyDown {
                    keyDown = true
                    emittedPress = false
                }
                cancelChord()
            }
        } else if raw == Self.systemDefinedRaw, keyDown, Self.isAuxControl(event) {
            cancelChord()
        }
        return Unmanaged.passUnretained(event)
    }

    private func cancelChord() {
        guard emittedPress else { return }
        emittedPress = false
        onEvent?(.cancelled)
    }

    private func teardown() {
        emittedPress = false
        keyDown = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        tapPort = nil
        runLoopSource = nil
        isRunning = false
    }

    /// Device-dependent flag bits from IOLLEvent.h. `CGEventFlags` does not name them.
    /// Right Option 0x40, Right Command 0x10, Right Control 0x2000 (`NX_DEVICERCTLKEYMASK`).
    private struct Spec {
        var keyCode: CGKeyCode
        var flag: CGEventFlags
        var deviceMask: UInt64
    }

    private static func spec(for hotkey: HotkeyChoice) -> Spec {
        switch hotkey {
        case .fn:
            return Spec(keyCode: CGKeyCode(kVK_Function), flag: .maskSecondaryFn, deviceMask: 0)
        case .rightOption:
            return Spec(keyCode: CGKeyCode(kVK_RightOption), flag: .maskAlternate, deviceMask: 0x40)
        case .rightCommand:
            return Spec(keyCode: CGKeyCode(kVK_RightCommand), flag: .maskCommand, deviceMask: 0x10)
        case .rightControl:
            return Spec(keyCode: CGKeyCode(kVK_RightControl), flag: .maskControl, deviceMask: 0x2000)
        }
    }

    /// Flag or device bit. Used when the event's keycode is not the hotkey.
    private static func hotkeyDown(_ spec: Spec, event: CGEvent) -> Bool {
        if spec.deviceMask != 0 {
            return event.flags.rawValue & spec.deviceMask != 0
        }
        return event.flags.contains(spec.flag)
    }

    /// flagsChanged whose keycode is this hotkey. If the device bit was stripped but the
    /// shared side-less flag is still set, toggle from the previous edge so right-key
    /// release is visible while the left key stays down.
    private static func edgeDown(_ spec: Spec, event: CGEvent, wasDown: Bool) -> Bool {
        if spec.deviceMask != 0 {
            if event.flags.rawValue & spec.deviceMask != 0 { return true }
            if !event.flags.contains(spec.flag) { return false }
            return !wasDown
        }
        return event.flags.contains(spec.flag)
    }

    /// True when a flagsChanged for a different key is that key going down, not up.
    private static func otherModifierPressed(code: CGKeyCode, event: CGEvent) -> Bool {
        if code == CGKeyCode(kVK_CapsLock) { return true }
        let raw = event.flags.rawValue
        if let device = deviceMask(for: code) {
            if raw & device != 0 { return true }
            if let flag = sharedFlag(for: code), !event.flags.contains(flag) { return false }
            if raw & deviceBits == 0, let flag = sharedFlag(for: code) {
                return event.flags.contains(flag)
            }
            return false
        }
        if let flag = sharedFlag(for: code) {
            return event.flags.contains(flag)
        }
        return true
    }

    private static func deviceMask(for code: CGKeyCode) -> UInt64? {
        switch Int(code) {
        case kVK_Shift: return 0x0002
        case kVK_RightShift: return 0x0004
        case kVK_Control: return 0x0001
        case kVK_RightControl: return 0x2000
        case kVK_Option: return 0x0020
        case kVK_RightOption: return 0x0040
        case kVK_Command: return 0x0008
        case kVK_RightCommand: return 0x0010
        default: return nil
        }
    }

    private static func sharedFlag(for code: CGKeyCode) -> CGEventFlags? {
        switch Int(code) {
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Function: return .maskSecondaryFn
        case kVK_CapsLock: return .maskAlphaShift
        default: return nil
        }
    }

    private static func isAuxControl(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        return nsEvent.subtype.rawValue == Int16(auxControlButtons)
    }

    private static func keyCode(_ event: CGEvent) -> CGKeyCode {
        CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    private static func mask(_ type: CGEventType) -> CGEventMask {
        maskRaw(type.rawValue)
    }

    private static func maskRaw(_ raw: UInt32) -> CGEventMask {
        CGEventMask(1) << CGEventMask(raw)
    }

    /// `NX_SYSDEFINED`. `CGEventType` has no case for it.
    private static let systemDefinedRaw: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`.
    private static let auxControlButtons: Int16 = 8
    /// OR of the side-specific modifier bits we consult.
    private static let deviceBits: UInt64 = 0x207F
}

private func hotkeyTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        monitor.receive(type: type, event: event)
    }
}
