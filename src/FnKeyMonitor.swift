import Cocoa

/// Watches the fn / 🌐 key system-wide with an active event tap and *swallows* the fn press,
/// so macOS never sees it and doesn't open the emoji picker,
/// switch input source, or start Apple Dictation. Needs Accessibility + Input Monitoring.
/// The tap runs on its own thread so typing never waits on the UI; callbacks arrive on the main thread.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// A normal key was pressed while fn was held (fn+arrow, fn+F, …) — not a dictation gesture.
    var onKeyWhileFnHeld: (() -> Void)?
    /// Control is held together with fn (pressed before or during the fn hold): Command Mode.
    /// Always delivered after the matching onFnDown.
    var onControlWithFn: (() -> Void)?
    var onEscape: (() -> Void)?

    /// While true, Esc is swallowed (it cancels dictation instead of also closing a dialog in the app).
    var swallowEscape: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _swallowEscape }
        set { lock.lock(); _swallowEscape = newValue; lock.unlock() }
    }

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var fnIsDown = false          // only touched on the tap thread
    private var controlIsDown = false     // only touched on the tap thread
    private var _swallowEscape = false
    private let lock = NSLock()

    private static let fnKeyCodes: Set<Int64> = [63, 179]   // kVK_Function, and the 🌐 key on newer keyboards
    private static let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }

        // Earliest point first (before macOS acts on the 🌐 key); fall back to the session tap.
        var created: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            created = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: refcon)
            if created != nil { break }
        }
        guard let tap = created else { return false }
        self.tap = tap

        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Verbaline.eventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
        return true
    }

    /// Runs on the tap thread. Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let down = event.flags.contains(.maskSecondaryFn)
            let control = event.flags.contains(.maskControl)
            if down != fnIsDown {
                fnIsDown = down
                let handler = down ? onFnDown : onFnUp
                DispatchQueue.main.async { handler?() }
                if down && control {
                    let command = onControlWithFn
                    DispatchQueue.main.async { command?() }
                }
            } else if fnIsDown && control && !controlIsDown {
                let command = onControlWithFn
                DispatchQueue.main.async { command?() }
            }
            controlIsDown = control
            // Swallow the fn key itself; let shift/cmd/etc. through untouched.
            return FnKeyMonitor.fnKeyCodes.contains(keyCode)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == FnKeyMonitor.escapeKeyCode {
                let swallow = swallowEscape
                DispatchQueue.main.async { [weak self] in self?.onEscape?() }
                return swallow
            }
            if fnIsDown {
                DispatchQueue.main.async { [weak self] in self?.onKeyWhileFnHeld?() }
            }
            return false

        default:
            return false
        }
    }
}
