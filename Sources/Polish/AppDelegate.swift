import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let store = ConfigStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon(working: false)

        PolishController.shared.onWorkingChange = { [weak self] working in
            self?.updateStatusIcon(working: working)
        }
        store.$config.map(\.enabled).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusIcon(working: PolishController.shared.isWorking) }
        }.store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               FocusInspector.isTrusted {
                FocusInspector.enableManualAccessibility(pid: app.processIdentifier)
            }
        }

        startMonitoring()
        if !FocusInspector.isTrusted || store.config.activeProvider?.needsKey != false {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    /// Launching the app again (Finder, Spotlight, Dock) while it runs in the background opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Right-click on the Dock icon (only visible while the settings window is open).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        populate(menu, includeQuit: false)
        return menu
    }

    // MARK: Permissions & monitoring

    private func startMonitoring() {
        if FocusInspector.isTrusted && KeyMonitor.shared.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateStatusIcon(working: false)
            return
        }
        FocusInspector.requestTrust()
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            if FocusInspector.isTrusted && KeyMonitor.shared.start() {
                self?.permissionTimer?.invalidate()
                self?.permissionTimer = nil
                self?.updateStatusIcon(working: false)
                HUD.shared.flash("辅助功能已授权，双击空格即可润色", kind: .success, duration: 2.5)
            }
        }
    }

    // MARK: Status item

    private func updateStatusIcon(working: Bool) {
        guard let button = statusItem?.button else { return }
        let name: String
        if working { name = "ellipsis.circle" }
        else if !KeyMonitor.shared.isRunning { name = "exclamationmark.triangle" }
        else if !store.config.enabled { name = "wand.and.stars.inverse" }
        else { name = "wand.and.stars" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Polish")
        img?.isTemplate = true
        button.image = img
        button.appearsDisabled = !store.config.enabled && !working
        button.toolTip = "Polish 润色 — 双击空格润色当前输入框"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu, includeQuit: true)
    }

    private func populate(_ menu: NSMenu, includeQuit: Bool) {
        let cfg = store.config

        let enable = NSMenuItem(title: "启用双击空格润色", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.target = self
        enable.state = cfg.enabled ? .on : .off
        menu.addItem(enable)

        if !KeyMonitor.shared.isRunning {
            let warn = NSMenuItem(title: "⚠️ 需要辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        // Language
        let langItem = NSMenuItem(title: "目标语言：\(Defaults.languageDisplay(cfg.targetLanguage))", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        var langs = Defaults.languages
        if !langs.contains(where: { $0.promptName == cfg.targetLanguage }) {
            langs.append(.init(display: cfg.targetLanguage, promptName: cfg.targetLanguage))
        }
        for l in langs {
            let it = NSMenuItem(title: l.display, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.promptName
            it.state = l.promptName == cfg.targetLanguage ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Tone
        let toneItem = NSMenuItem(title: "语气：\(cfg.activeTone?.name ?? "-")", action: nil, keyEquivalent: "")
        let toneMenu = NSMenu()
        for t in cfg.tones {
            let it = NSMenuItem(title: t.name, action: #selector(selectTone(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.id
            it.state = t.id == cfg.activeTone?.id ? .on : .off
            toneMenu.addItem(it)
        }
        toneItem.submenu = toneMenu
        menu.addItem(toneItem)

        // Model
        let modelItem = NSMenuItem(title: "模型：\(cfg.activeModel)", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for p in cfg.providers {
            let header = NSMenuItem(title: p.name + (p.needsKey ? "（未填 Key）" : ""), action: nil, keyEquivalent: "")
            header.isEnabled = false
            modelMenu.addItem(header)
            for m in p.models {
                let it = NSMenuItem(title: m, action: #selector(selectModel(_:)), keyEquivalent: "")
                it.target = self
                it.indentationLevel = 1
                it.representedObject = [p.id.uuidString, m]
                it.state = (p.id == cfg.activeProviderID && m == cfg.activeModel) ? .on : .off
                modelMenu.addItem(it)
            }
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        if includeQuit {
            let quit = NSMenuItem(title: "退出 Polish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)
        }
    }

    @objc private func toggleEnabled() { store.config.enabled.toggle() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { store.config.targetLanguage = s }
    }

    @objc private func selectTone(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { store.config.activeToneID = id }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let id = UUID(uuidString: pair[0]) else { return }
        store.select(providerID: id, model: pair[1])
    }

    @objc func openAccessibilitySettings() {
        FocusInspector.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startMonitoring()
    }

    // MARK: Settings window

    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(openAccessibility: { [weak self] in
                self?.openAccessibilitySettings()
            }).environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = "Polish 设置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 560))
            w.minSize = NSSize(width: 680, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        // Show in the Dock only while settings are open; otherwise run as a menu-bar-only app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
        // Hand focus back to the app the user was typing in.
        DispatchQueue.main.async { NSApp.hide(nil) }
    }

    // MARK: Main menu (needed so Cmd+C/V/A/Z work inside the settings window)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 Polish", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "退出 Polish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        win.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
    }
}
