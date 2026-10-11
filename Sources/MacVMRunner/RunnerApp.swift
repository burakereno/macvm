import AppKit
import Virtualization
import MacVMCore

@main
struct RunnerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = RunnerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class RunnerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency VZVirtualMachineDelegate, NSToolbarDelegate {
    private var directory: URL!
    private var record: VirtualMachineRecord!
    private var machine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var window: NSWindow?
    private var lock: VMLock?
    private var timer: Timer?
    private let session = UUID()
    private var phase: RuntimePhase = .starting
    private var terminating = false
    private var lastMessage: String?
    private var pauseItem: NSToolbarItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--bundle"), arguments.indices.contains(index + 1) else {
                throw VMError.message("Open a virtual machine from MacVM to use this application.")
            }
            directory = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            lock = try VMLock(directory: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Command.json"))
            record = try VMStorage.validateBundle(at: directory)
            let configuration = try VMConfigurationFactory.make(record: record, directory: directory)
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            self.machine = machine
            buildMenu()
            buildWindow(machine: machine)
            publish(.starting)
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            if record.installationPending { try installMacOS() } else { start() }
            NSApp.activate(ignoringOtherApps: true)
        } catch { fail(error) }
    }

    private func buildWindow(machine: VZVirtualMachine) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = record.name
        window.contentView = view
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("vm-\(record.id.uuidString)")
        let toolbar = NSToolbar(identifier: "VMToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(record.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let vmItem = NSMenuItem(); let vmMenu = NSMenu(title: "Virtual Machine")
        vmMenu.addItem(withTitle: "Pause / Resume", action: #selector(togglePause), keyEquivalent: "p")
        vmMenu.addItem(withTitle: "Shut Down", action: #selector(shutdown), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Force Stop…", action: #selector(confirmForceStop), keyEquivalent: "")
        vmItem.submenu = vmMenu; menu.addItem(vmItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("pause"), .init("stop")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("pause"), .init("stop")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        if identifier.rawValue == "pause" {
            item.label = "Pause"; item.toolTip = "Pause or resume this machine"
            item.image = NSImage(systemSymbolName: "pause", accessibilityDescription: "Pause")
            item.action = #selector(togglePause); pauseItem = item
        } else {
            item.label = "Shut Down"; item.toolTip = "Ask the guest operating system to shut down"
            item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Shut Down")
            item.action = #selector(shutdown)
        }
        return item
    }

    private func installMacOS() throws {
        guard let path = record.restoreImagePath, FileManager.default.fileExists(atPath: path) else {
            throw VMError.message("The macOS restore image is missing. Choose an IPSW in machine settings to retry installation.")
        }
        guard let machine else { return }
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: URL(fileURLWithPath: path))
        self.installer = installer
        publish(.installing)
        Task { @MainActor in
            do {
                try await installer.install()
                self.installer = nil
                self.record.installationPending = false
                self.record.restoreImagePath = nil
                try self.record.save(to: self.directory)
                self.start()
            } catch {
                self.installer = nil
                self.fail(error)
            }
        }
    }

    private func start() {
        publish(.starting)
        machine?.start { [weak self] result in
            switch result {
            case .success: self?.publish(.running)
            case .failure(let error): self?.fail(error)
            }
        }
    }

    @objc private func togglePause() {
        guard let machine, installer == nil else { return }
        if machine.canPause {
            machine.pause { [weak self] result in
                switch result {
                case .success: self?.publish(.paused)
                case .failure(let error): self?.report(error)
                }
            }
        } else if machine.canResume {
            machine.resume { [weak self] result in
                switch result {
                case .success: self?.publish(.running)
                case .failure(let error): self?.report(error)
                }
            }
        }
    }

    @objc private func shutdown() {
        guard let machine, installer == nil else { return }
        if machine.state == .paused {
            machine.resume { [weak self] result in
                switch result {
                case .success: self?.publish(.running); self?.shutdown()
                case .failure(let error): self?.report(error)
                }
            }
            return
        }
        do {
            guard machine.canRequestStop else {
                throw VMError.message("The guest cannot shut down yet. Use its power menu, or Force Stop if it is unresponsive.")
            }
            try machine.requestStop()
            publish(.stopping)
        } catch { report(error) }
    }

    @objc private func confirmForceStop() {
        guard installer == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Force stop \(record.name)?"
        alert.informativeText = "Unsaved changes inside the virtual machine will be lost."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Force Stop")
        if alert.runModal() == .alertSecondButtonReturn { forceStop() }
    }

    private func forceStop() {
        guard let machine, installer == nil, machine.canStop else { return }
        machine.stop { [weak self] error in
            if let error { self?.report(error) } else { self?.finish() }
        }
    }

    private func poll() {
        if phase == .installing { publish(.installing, progress: installer?.progress.fractionCompleted) }
        let commandURL = directory.appendingPathComponent("Command.json")
        guard let data = try? Data(contentsOf: commandURL) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        guard let command = try? JSONDecoder().decode(RuntimeCommand.self, from: data), command.session == session else { return }
        switch command.action {
        case .show: window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case .pause: if phase == .running { togglePause() }
        case .resume: if phase == .paused { togglePause() }
        case .shutdown: shutdown()
        case .forceStop: forceStop()
        }
    }

    private func publish(_ phase: RuntimePhase, progress: Double? = nil, message: String? = nil) {
        self.phase = phase; lastMessage = message
        let status = RuntimeStatus(phase: phase, session: session, progress: progress, message: message)
        try? status.save(to: directory)
        window?.subtitle = phase == .installing ? "Installing macOS · \(Int((progress ?? 0) * 100))%" : phase.title
        pauseItem?.image = NSImage(systemSymbolName: phase == .paused ? "play" : "pause", accessibilityDescription: phase == .paused ? "Resume" : "Pause")
        pauseItem?.label = phase == .paused ? "Resume" : "Pause"
        pauseItem?.isEnabled = phase == .running || phase == .paused
    }

    private func report(_ error: Error) {
        publish(phase, message: error.localizedDescription)
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func fail(_ error: Error) {
        // Never overwrite the status of a different runner that owns the lock.
        if lock != nil { publish(.failed, message: error.localizedDescription) }
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
        terminating = true
        NSApp.terminate(nil)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { if installer == nil { finish() } }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { fail(error) }
    private func finish() {
        guard !terminating else { return }
        publish(.stopped)
        terminating = true
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating || !phase.isActive { return .terminateNow }
        if installer != nil {
            let alert = NSAlert(); alert.messageText = "macOS is still installing"
            alert.informativeText = "Keep this window open until installation finishes. You can minimize it while you wait."
            alert.runModal(); return .terminateCancel
        }
        shutdown()
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if terminating || !phase.isActive { return true }
        let alert = NSAlert()
        alert.messageText = "Keep \(record.name) running?"
        alert.informativeText = "Closing this window can leave the machine running in the background. Reopen it from MacVM."
        alert.addButton(withTitle: "Keep Running")
        if installer == nil { alert.addButton(withTitle: "Shut Down") }
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn { sender.orderOut(nil) }
        else if result == .alertSecondButtonReturn && installer == nil { shutdown() }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); lock = nil }
}
