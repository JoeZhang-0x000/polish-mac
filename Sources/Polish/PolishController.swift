import AppKit
import Carbon

/// Orchestrates one polish: copy the field, call the model, paste the result, remember it for undo.
final class PolishController {
    static let shared = PolishController()

    private(set) var isWorking = false {
        didSet { if oldValue != isWorking { onWorkingChange?(isWorking) } }
    }
    var onWorkingChange: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0

    private struct Record {
        let pid: pid_t
        let original: String
        let polished: String
        var undone = false
    }
    private var last: Record?

    private var config: AppConfig { ConfigStore.shared.config }

    // MARK: Trigger

    func shouldTrigger() -> Bool {
        guard FocusInspector.isTrusted, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return false }
        if let bid = app.bundleIdentifier, config.excludedBundleIDs.contains(bid) { return false }
        switch FocusInspector.classify(FocusInspector.focusedElement()) {
        case .text: return true
        case .nonText: return false
        case .unknown: return config.triggerInUnknownFields
        }
    }

    func trigger() {
        guard !isWorking, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let element = FocusInspector.focusedElement()
        generation += 1
        let gen = generation
        isWorking = true
        last = nil
        HUD.shared.showProgress("润色中…  Esc 取消", near: FocusInspector.anchorRect(element))
        task = Task { @MainActor [weak self] in
            await self?.run(gen: gen, pid: pid, element: element)
        }
    }

    func cancel(message: String) {
        guard isWorking else { return }
        generation += 1
        task?.cancel()
        task = nil
        isWorking = false
        HUD.shared.flash(message, kind: .info)
    }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    @MainActor
    private func run(gen: Int, pid: pid_t, element: AXUIElement?) async {
        defer { if gen == generation { isWorking = false } }

        let snapshot = PasteboardSnapshot()
        let copied = await Clipboard.copyAllText()
        if copied != nil { KeySynth.moveRight() } // collapse the selection so stray typing can't wipe the field
        snapshot.restore()
        guard isCurrent(gen) else { return }

        guard let original = copied, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HUD.shared.flash("没有可润色的文字", kind: .info)
            return
        }
        if original.count > config.maxChars {
            HUD.shared.flash("文本过长（\(original.count) 字，上限 \(config.maxChars)）", kind: .error)
            return
        }

        do {
            let polished = try await LLMClient.polish(
                original.trimmingCharacters(in: .whitespacesAndNewlines), config: config)
            guard isCurrent(gen) else { return }

            let sameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            let now = FocusInspector.focusedElement()
            let sameField = element == nil || now == nil || CFEqual(element, now)
            guard sameApp && sameField else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(polished, forType: .string)
                HUD.shared.flash("输入焦点已改变，润色结果已复制到剪贴板", kind: .info)
                return
            }

            await Clipboard.replaceAll(with: polished)
            last = Record(pid: pid, original: original, polished: polished)
            HUD.shared.flash("✓ 已润色 · ⌘Z 撤销", kind: .success)
        } catch {
            guard isCurrent(gen) else { return }
            HUD.shared.flash(error.localizedDescription, kind: .error, duration: 4)
        }
    }

    // MARK: Undo / redo

    /// Cmd+Z right after a polish restores the original text. Returns true if the key was handled.
    func handleUndo() -> Bool {
        guard config.takeOverUndo, var r = last, !r.undone,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == r.pid else { return false }
        r.undone = true
        last = r
        Task { @MainActor in
            await Clipboard.replaceAll(with: r.original)
            HUD.shared.flash("↶ 已恢复原文 · ⇧⌘Z 重做", kind: .info)
        }
        return true
    }

    func handleRedo() -> Bool {
        guard config.takeOverUndo, var r = last, r.undone,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == r.pid else { return false }
        r.undone = false
        last = r
        Task { @MainActor in
            await Clipboard.replaceAll(with: r.polished)
            HUD.shared.flash("↷ 已重新应用润色", kind: .success)
        }
        return true
    }

    /// Any other keystroke ends the undo window; from then on Cmd+Z belongs to the app.
    func userTyped() {
        last = nil
    }
}
