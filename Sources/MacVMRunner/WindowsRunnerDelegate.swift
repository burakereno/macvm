import AppKit
import MacVMCore
import MacVMUI
import WindowsPrototypeCore

@MainActor
final class WindowsRunnerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private var directory: URL!
    private var record: VirtualMachineRecord!
    private var lock: VMLock?
    private var usageLock: AppUsageLock?
    private let engine = WindowsSession()
    private let display = WindowsDisplayView()
    private let integration = WindowsIntegrationController()
    private let session = UUID()
    private var phase: RuntimePhase = .starting
    private var window: NSWindow?
    private var timer: Timer?
    private var terminating = false
    private var screenTransition = false
    private var keyMonitor: Any?
    private var pauseItem: NSToolbarItem?
    private var stopItem: NSToolbarItem?
    private var screenItem: NSToolbarItem?
    private var screenMenu: NSMenuItem?
    private var failure: String?
    private var storageError: String?
    private var alert: NSAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--bundle"), CommandLine.arguments.indices.contains(index + 1), let resources = Bundle.main.resourceURL else {
                throw VMError.message("Open this machine from MacVM.")
            }
            directory = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            usageLock = try AppUsageLock(exclusive: false)
            lock = try VMLock(directory: directory)
            record = try VMStorage.validateBundle(at: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Command.json"))
            let config = try WindowsConfiguration.installed(record: record, directory: directory, resources: resources)
            NSApp.applicationIconImage = GuestBrandArtwork.dockIcon(for: .windows)
            buildWindow(); buildMenu(); publish(.starting)
            integration.onReminder = { [weak self] in self?.remindTools() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
            display.client.onFrame = { [weak self] image in self?.display.image = image }
            display.client.onFailure = { [weak self] message in
                guard let self, !self.terminating else { return }
                self.failure = message; self.publish(self.phase, message: message)
                self.showError(message)
            }
            engine.start(config, ownsLock: true, embeddedDisplay: true, displayReady: { [weak self] url in
                self?.display.client.start(socketURL: url)
                if let self { self.integration.start(runtime: url.deletingLastPathComponent(), record: self.record, window: self.window) }
            }) { [weak self] state, message in self?.engineChanged(state, message: message) }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            if lock != nil { publish(.failed, message: error.localizedDescription) }
            NSAlert(error: error).runModal(); terminating = true; NSApp.terminate(nil)
        }
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = record.name; window.contentView = display; window.minSize = NSSize(width: 640, height: 440)
        window.collectionBehavior.insert(.fullScreenPrimary); window.isReleasedWhenClosed = false; window.delegate = self
        window.setFrameAutosaveName("vm-\(record.id.uuidString)")
        let toolbar = NSToolbar(identifier: "VMToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; window.toolbar = toolbar
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(display); self.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp]) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window, event.keyCode == 3,
                  event.modifierFlags.intersection([.control,.command,.option,.shift]) == [.control,.command] else { return event }
            if event.type == .keyDown && !event.isARepeat { self.toggleFullScreen() }; return nil
        }
    }
    private func buildMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.submenu = NSMenu(title: title); menu.addItem(item); return item.submenu!
        }
        submenu(record.name).addItem(withTitle: "Quit \(record.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let machine = submenu("Virtual Machine")
        machine.addItem(withTitle: "Pause / Resume", action: #selector(togglePause), keyEquivalent: "p")
        machine.addItem(withTitle: "Shut Down", action: #selector(shutdown), keyEquivalent: "")
        machine.addItem(withTitle: "Force Stop…", action: #selector(confirmForceStop), keyEquivalent: "")
        machine.addItem(withTitle: "Install Windows Tools…", action: #selector(installDisplayTools), keyEquivalent: "")
        machine.addItem(withTitle: "Windows Tools Status…", action: #selector(toolsStatus), keyEquivalent: "")
        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        let item = NSMenuItem(title: "Enter Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.control,.command]; item.target = self; windows.addItem(item); screenMenu = item
        NSApp.mainMenu = menu; NSApp.windowsMenu = windows
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace,.init("fullscreen"),.init("pause"),.init("stop")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id); item.target = self; item.autovalidates = false
        switch id.rawValue {
        case "fullscreen": item.label = "Enter Full Screen"; item.toolTip = "Enter Full Screen · ⌃⌘F"; item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: item.label); item.action = #selector(toggleFullScreen); screenItem = item
        case "pause": item.label = "Pause"; item.toolTip = "Pause or resume this machine"; item.image = NSImage(systemSymbolName: "pause", accessibilityDescription: "Pause"); item.action = #selector(togglePause); pauseItem = item
        default: item.label = "Shut Down"; item.toolTip = "Ask Windows to shut down"; item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Shut Down"); item.action = #selector(shutdown); stopItem = item
        }; return item
    }
    @objc private func installDisplayTools() {
        guard phase == .running, alert == nil else { return }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("WindowsEngine/DisplayTools.iso"),
              FileManager.default.fileExists(atPath: url.path) else {
            showError("Display Tools are not included in this development build."); return
        }
        engine.mountDisplayTools(url) { [weak self] error in
            guard let self else { return }
            if let error { self.showError(error); return }
            let box = NSAlert(); box.messageText = "Install Windows Tools"
            box.informativeText = "In Windows, open This PC → MacVM Tools. Right-click Install.cmd and choose Run as administrator. This installs display, network and integration drivers, text clipboard and shared-folder helpers. Follow its restart instructions; upgrading an older display driver may require running it again. After installation, shut down Windows and enable Automatic display resolution in Machine Settings before starting again. Windows Tools Status confirms the connection. Set Windows display scaling to 200% for Retina. Shared folders selected in Machine Settings appear at \\\\localhost@9843\\DavWWWRoot."
            box.addButton(withTitle: "OK"); self.alert = box
            if let window = self.window { box.beginSheetModal(for: window) { [weak self] _ in self?.alert = nil } }
        }
    }
    private func remindTools() {
        guard phase == .running, alert == nil, window?.isVisible == true else { return }
        let box = NSAlert(); box.messageText = "Windows Tools are not connected"
        box.informativeText = "Install Windows Tools for automatic display sizing, text clipboard and shared folders. If you just installed them, restart Windows and sign in. You can install or check status later from Virtual Machine."
        box.addButton(withTitle: "Install Tools…"); box.addButton(withTitle: "Later"); alert = box
        if let window { box.beginSheetModal(for: window) { [weak self] response in
            self?.alert = nil; if response == .alertFirstButtonReturn { self?.installDisplayTools() }
        } }
    }
    @objc private func toolsStatus() { showError(integration.status + ". Clipboard shares text only while this VM is active. Shared folders: This PC → \\\\localhost@9843\\DavWWWRoot.") }
    @objc private func togglePause() {
        guard [.running,.paused].contains(phase) else { return }
        display.releaseInput(); engine.perform(phase == .paused ? .resume : .pause)
    }
    @objc private func shutdown() {
        guard [.running,.paused,.stopping].contains(phase) else { return }
        if phase == .stopping { shutdownOptions(); return }
        display.releaseInput(); engine.perform(.shutdown)
    }
    private func shutdownOptions() {
        guard alert == nil else { return }
        let box = NSAlert(); box.messageText = "Windows is still running"
        box.informativeText = "You can shut down from Windows’ power menu. Force Stop may lose unsaved work."
        box.addButton(withTitle: "Keep Waiting"); box.addButton(withTitle: "Force Stop")
        alert = box
        if let window { box.beginSheetModal(for: window) { [weak self] response in
            self?.alert = nil
            if response == .alertSecondButtonReturn { self?.engine.perform(.forceStop) }
        } }
    }
    @objc private func confirmForceStop() {
        guard phase.isActive, alert == nil else { return }
        let box = NSAlert(); box.messageText = "Force stop \(record.name)?"; box.informativeText = "Unsaved work may be lost."
        box.addButton(withTitle: "Cancel"); box.addButton(withTitle: "Force Stop"); alert = box
        if let window { box.beginSheetModal(for: window) { [weak self] response in
            self?.alert = nil
            if response == .alertSecondButtonReturn { self?.engine.perform(.forceStop) }
        } }
    }
    @objc private func toggleFullScreen() {
        guard !screenTransition, window?.attachedSheet == nil else { return }
        display.releaseInput(); window?.toggleFullScreen(nil)
    }
    private func updateScreen() {
        let full = window?.styleMask.contains(.fullScreen) == true
        let title = full ? "Exit Full Screen" : "Enter Full Screen"
        screenMenu?.title = title; screenItem?.label = title; screenItem?.toolTip = "\(title) · ⌃⌘F"; screenItem?.isEnabled = !screenTransition
        screenItem?.image = NSImage(systemSymbolName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: title)
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions { proposedOptions.subtracting(.autoHideToolbar) }
    func windowWillEnterFullScreen(_ notification: Notification) { screenTransition = true; display.defersResolutionChanges = true; updateScreen() }
    func windowWillExitFullScreen(_ notification: Notification) { screenTransition = true; display.defersResolutionChanges = true; updateScreen() }
    func windowDidEnterFullScreen(_ notification: Notification) { screenTransition = false; display.defersResolutionChanges = false; updateScreen() }
    func windowDidExitFullScreen(_ notification: Notification) { screenTransition = false; display.defersResolutionChanges = false; updateScreen() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { screenTransition = false; display.defersResolutionChanges = false; updateScreen() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { screenTransition = false; display.defersResolutionChanges = false; updateScreen() }
    func windowDidResignKey(_ notification: Notification) { display.releaseInput() }
    private func engineChanged(_ state: String, message: String) {
        guard !terminating else { return }
        switch state {
        case "Stopped": finish()
        case "Failed": publish(.failed, message: message); showError(message, exit: true)
        case "Error": publish(phase, message: message); showError(message)
        case "IOError":
            let changed = storageError != message
            storageError = message; publish(.paused, message: message)
            if changed { showError(message) }
        default:
            storageError = nil
            let next = RuntimePhase(rawValue: state.lowercased()) ?? phase
            let timeout = message.hasPrefix("Shutdown timed out")
            publish(next, message: failure ?? (timeout ? message : nil))
            if timeout { shutdownOptions() }
        }
    }
    private func publish(_ phase: RuntimePhase, message: String? = nil) {
        self.phase = phase
        if lock != nil { try? RuntimeStatus(phase: phase, session: session, message: message).save(to: directory) }
        window?.subtitle = phase.title
        pauseItem?.label = phase == .paused ? "Resume" : "Pause"
        pauseItem?.image = NSImage(systemSymbolName: phase == .paused ? "play" : "pause", accessibilityDescription: pauseItem?.label)
        pauseItem?.isEnabled = [.running,.paused].contains(phase)
        stopItem?.isEnabled = [.running,.paused,.stopping].contains(phase)
        stopItem?.label = phase == .stopping ? "Shutdown Options…" : "Shut Down"
    }
    private func poll() {
        guard !terminating else { return }
        integration.poll(running: phase == .running, installing: record.windowsInstallationPending == true || record.bootFromInstaller)
        let url = directory.appendingPathComponent("Command.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let command = try? JSONDecoder().decode(RuntimeCommand.self, from: data), command.session == session else { return }
        switch command.action {
        case .show: window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case .pause: if phase == .running { togglePause() }
        case .resume: if phase == .paused { togglePause() }
        case .shutdown: shutdown()
        case .forceStop: engine.perform(.forceStop)
        case .retrySetup: break
        }
    }
    private func showError(_ message: String, exit: Bool = false) {
        guard alert == nil else { return }
        let box = NSAlert(); box.messageText = "Windows"; box.informativeText = message; box.addButton(withTitle: "OK"); alert = box
        if let window { box.beginSheetModal(for: window) { [weak self] _ in
            self?.alert = nil
            if exit { self?.terminating = true; NSApp.terminate(nil) }
        } }
    }
    private func finish() {
        terminating = true; display.client.stop(); integration.stop(); timer?.invalidate()
        if let alert { window?.endSheet(alert.window) }; alert = nil
        publish(.stopped); NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || !phase.isActive { return .terminateNow }; shutdown(); return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminating || !phase.isActive { return true }
        let box = NSAlert(); box.messageText = "Keep \(record.name) running?"
        box.informativeText = "Reopen this machine from MacVM."
        box.addButton(withTitle: "Keep Running"); box.addButton(withTitle: "Shut Down"); box.addButton(withTitle: "Cancel")
        let response = box.runModal()
        if response == .alertFirstButtonReturn { display.releaseInput(); sender.orderOut(nil) }
        else if response == .alertSecondButtonReturn { shutdown() }
        return false
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(installDisplayTools): return phase == .running && alert == nil
        case #selector(togglePause): return [.running,.paused].contains(phase)
        case #selector(shutdown): return [.running,.paused,.stopping].contains(phase)
        case #selector(confirmForceStop): return phase.isActive
        case #selector(toggleFullScreen): return !screenTransition && window?.attachedSheet == nil
        default: return true
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.makeKeyAndOrderFront(nil); return true }
    func applicationWillTerminate(_ notification: Notification) {
        display.client.stop(); integration.stop(); timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        lock = nil
    }
}
