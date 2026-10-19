import AppKit
import Carbon.HIToolbox

/// Global keyboard tap: detects double space, Esc during a request, and Cmd+Z / Cmd+Shift+Z right after a polish.
final class KeyMonitor {
    static let shared = KeyMonitor()

    private var tap: CFMachPort?
    private var lastSpaceAt: TimeInterval = 0

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            KeyMonitor.shared.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: nil) else {
            return false
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != KeySynth.marker else {
            return Unmanaged.passUnretained(event)
        }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let controller = PolishController.shared

        // While a request is in flight: Esc cancels, any other typing cancels too.
        if controller.isWorking {
            lastSpaceAt = 0
            if key == kVK_Escape && mods.isEmpty {
                controller.cancel(message: "已取消")
                return nil
            }
            controller.cancel(message: "检测到键盘输入，已取消润色")
            return Unmanaged.passUnretained(event)
        }

        if key == kVK_ANSI_Z && mods == .maskCommand, controller.handleUndo() { return nil }
        if key == kVK_ANSI_Z && mods == [.maskCommand, .maskShift], controller.handleRedo() { return nil }
        controller.userTyped()

        guard key == kVK_Space, mods.isEmpty, !isRepeat else {
            lastSpaceAt = 0
            return Unmanaged.passUnretained(event)
        }

        let cfg = ConfigStore.shared.config
        let now = ProcessInfo.processInfo.systemUptime
        if lastSpaceAt > 0, now - lastSpaceAt <= cfg.doubleSpaceInterval {
            lastSpaceAt = 0
            if cfg.enabled, controller.shouldTrigger() {
                controller.trigger()
                return nil // swallow the second space
            }
            return Unmanaged.passUnretained(event)
        }
        lastSpaceAt = now
        return Unmanaged.passUnretained(event)
    }
}
