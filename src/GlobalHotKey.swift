import Carbon

/// A system-wide keyboard shortcut (e.g. ⌃⌘V). Uses Carbon's RegisterEventHotKey, which needs
/// no extra permission and swallows the keystroke so the frontmost app doesn't also see it.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        GlobalHotKey.handlers[id] = handler
        GlobalHotKey.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5654_5950), id: id) // 'VTYP'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            GlobalHotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
