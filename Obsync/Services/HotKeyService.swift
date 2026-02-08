import Carbon
import Foundation

/// Registers a global keyboard shortcut using the Carbon API.
/// Works within the macOS app sandbox without additional entitlements.
class HotKeyService {
    static let shared = HotKeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?

    private init() {}

    /// Register a global hotkey. Only one hotkey is supported at a time.
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        unregister()
        self.callback = callback

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4F525353) // "ORSS"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                service.callback?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        callback = nil
    }

    /// Human-readable description of the current hotkey
    static func describeHotKey(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        if modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }

        // Map common key codes to characters
        let keyName: String
        switch Int(keyCode) {
        case kVK_ANSI_S: keyName = "S"
        case kVK_ANSI_R: keyName = "R"
        case kVK_ANSI_O: keyName = "O"
        default: keyName = "Key\(keyCode)"
        }
        parts.append(keyName)

        return parts.joined()
    }
}
