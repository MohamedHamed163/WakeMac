import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey`, which — unlike
/// `NSEvent.addGlobalMonitorForEvents` — needs no Accessibility permission.
/// A global monitor silently never fires until the user grants that
/// permission, which makes a shortcut look broken rather than blocked.
public final class GlobalHotKey {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: UInt32(cmdKey))
        public static let option  = Modifiers(rawValue: UInt32(optionKey))
        public static let control = Modifiers(rawValue: UInt32(controlKey))
        public static let shift   = Modifiers(rawValue: UInt32(shiftKey))
    }

    private static let signature: OSType = 0x574B4D43   // 'WKMC'
    @MainActor private static var nextID: UInt32 = 1
    @MainActor private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    @MainActor private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// Registers `keyCode` + `modifiers`. Returns nil when the combination is
    /// already taken by another application.
    @MainActor
    public init?(keyCode: UInt32, modifiers: Modifiers, handler: @escaping @MainActor () -> Void) {
        Self.installDispatcherIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        reference = ref
        Self.handlers[id] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        let id = self.id
        Task { @MainActor in GlobalHotKey.handlers[id] = nil }
    }

    /// One process-wide Carbon handler fans out to the registered closures.
    @MainActor
    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return noErr }
            let firedID = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.handlers[firedID]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}

public extension GlobalHotKey {
    /// Virtual key codes for the shortcuts these apps register.
    enum Key {
        public static let space: UInt32 = 49
        public static let n: UInt32 = 45
        public static let a: UInt32 = 0
        public static let o: UInt32 = 31
        public static let i: UInt32 = 34
    }
}
