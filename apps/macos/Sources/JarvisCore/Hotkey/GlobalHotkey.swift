import Carbon.HIToolbox
import Foundation

public enum HotkeyConfiguration: String, Sendable, Codable, CaseIterable, Equatable {
    case commandShiftSpace
    case optionSpace
    case controlSpace

    public var keyCode: UInt32 { UInt32(kVK_Space) }

    public var modifiers: UInt32 {
        switch self {
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        }
    }

    public var displayName: String {
        switch self {
        case .commandShiftSpace: "⌘⇧Space"
        case .optionSpace: "⌥Space"
        case .controlSpace: "⌃Space"
        }
    }
}

public enum HotkeyPhase: Sendable, Equatable {
    case pressed
    case released

    public init?(eventKind: UInt32) {
        switch eventKind {
        case UInt32(kEventHotKeyPressed): self = .pressed
        case UInt32(kEventHotKeyReleased): self = .released
        default: return nil
        }
    }
}

@MainActor
public final class GlobalHotkey {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    public init() {}

    deinit {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
    }

    public func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey),
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void
    ) throws {
        unregister()
        self.onPressed = onPressed
        self.onReleased = onReleased

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                Task { @MainActor in owner.handle(eventKind: kind) }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard installStatus == noErr else {
            throw GlobalHotkeyError.registrationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4A_41_52_56), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registerStatus == noErr else {
            unregister()
            throw GlobalHotkeyError.registrationFailed(registerStatus)
        }
    }

    public func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
        onPressed = nil
        onReleased = nil
    }

    private func handle(eventKind: UInt32) {
        switch HotkeyPhase(eventKind: eventKind) {
        case .pressed: onPressed?()
        case .released: onReleased?()
        case nil: break
        }
    }
}

public enum GlobalHotkeyError: Error {
    case registrationFailed(OSStatus)
}
