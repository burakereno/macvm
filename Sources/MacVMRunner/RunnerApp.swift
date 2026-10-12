import AppKit
import Virtualization
import MacVMCore
import SwiftUI
import MacVMUI

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
final class RunnerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency VZVirtualMachineDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private var directory: URL!
    private var record: VirtualMachineRecord!
    private var machine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var installationImageLease: ImageLease?
    private var window: NSWindow?
    private var lock: VMLock?
    private var applicationUsageLock: AppUsageLock?
    private var timer: Timer?
    private let session = UUID()
    private var phase: RuntimePhase = .starting
    private var terminating = false
    private var lastMessage: String?
    private var pauseItem: NSToolbarItem?
    private var stopItem: NSToolbarItem?
    private var fullScreenItem: NSToolbarItem?
    private var fullScreenMenuItem: NSMenuItem?
    private var fullScreenKeyMonitor: Any?
    private var fullScreenTransitionInFlight = false
    private var shutdownWait = ShutdownWait()
    private var shutdownTimedOut = false
    private var shutdownAlert: NSAlert?
    private var operationInFlight = false
    private var guestShutdownClient: GuestShutdownClient?
    private var guestToolsWindow: NSWindow?
    private var guestToolsReminder: GuestToolsReminderController?
    private let clipboardController = GuestClipboardController()
    private let shutdownTimeoutMessage = "The guest did not shut down. Use its power menu, or choose Force Stop to turn it off."

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--bundle"), arguments.indices.contains(index + 1) else {
                throw VMError.message("Open a virtual machine from MacVM to use this application.")
            }
            directory = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            applicationUsageLock = try AppUsageLock(exclusive: false)
            lock = try VMLock(directory: directory)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Command.json"))
            record = try VMStorage.validateBundle(at: directory)
            let toolsURL = Bundle.main.resourceURL?.appendingPathComponent("GuestTools", isDirectory: true)
            let configuration = try VMConfigurationFactory.make(record: record, directory: directory,
                guestToolsURL: toolsURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            if record.system == .linux, let logIndex = arguments.firstIndex(of: "--serial-log") {
                guard arguments.indices.contains(logIndex + 1) else {
                    throw VMError.message("The serial log option requires a file path.")
                }
                let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
                serial.attachment = try VZFileSerialPortAttachment(url: URL(fileURLWithPath: arguments[logIndex + 1]), append: true)
                configuration.serialPorts = [serial]
                try configuration.validate()
            }
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            self.machine = machine
            buildMenu()
            buildWindow(machine: machine)
            installFullScreenShortcut()
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
        view.capturesSystemKeys = false
        // Preserve the display's full pixel density; UI scaling belongs to the guest.
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.collectionBehavior.insert(.fullScreenPrimary)
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
        if record.system == .macOS {
            let reminder = GuestToolsReminderController(window: window, machineName: record.name) { [weak self] in
                self?.showGuestTools()
            }
            reminder.onStatusChange = { [weak self] status in self?.updateGuestToolsWarning(status) }
            guestToolsReminder = reminder
        }
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
        if record.system == .macOS {
            vmMenu.addItem(.separator())
            vmMenu.addItem(withTitle: "Guest Tools…", action: #selector(showGuestTools), keyEquivalent: "")
        }
        vmItem.submenu = vmMenu; menu.addItem(vmItem)
        let windowItem = NSMenuItem(); let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        fullScreen.target = self
        windowMenu.addItem(fullScreen)
        fullScreenMenuItem = fullScreen
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace, .init("fullscreen"), .init("pause"), .init("stop")]
        if record.system == .macOS { identifiers.insert(.init("guestToolsSetup"), at: 0) }
        return identifiers
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar).filter { $0.rawValue != "guestToolsSetup" }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.autovalidates = false
        if identifier.rawValue == "guestToolsSetup" {
            item.label = "Set Up Guest Tools…"
            item.toolTip = "Guest Tools are not connected · Set Up Guest Tools…"
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Set Up Guest Tools")
            item.action = #selector(showGuestTools)
        } else if identifier.rawValue == "pause" {
            item.label = "Pause"; item.toolTip = "Pause or resume this machine"
            item.image = NSImage(systemSymbolName: "pause", accessibilityDescription: "Pause")
            item.action = #selector(togglePause); pauseItem = item
        } else if identifier.rawValue == "fullscreen" {
            item.label = "Enter Full Screen"
            item.toolTip = "Enter Full Screen · ⌃⌘F"
            item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Enter Full Screen")
            item.action = #selector(toggleFullScreen)
            fullScreenItem = item
        } else {
            item.label = "Shut Down"; item.toolTip = "Ask the guest operating system to shut down"
            item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Shut Down")
            item.action = #selector(shutdown); stopItem = item
        }
        return item
    }

    private func updateGuestToolsWarning(_ status: GuestToolsAvailability.Status) {
        guard record.system == .macOS, let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "guestToolsSetup" }
        if status == .notConnected, index == nil { toolbar.insertItem(withItemIdentifier: .init("guestToolsSetup"), at: 0) }
        else if status != .notConnected, let index { toolbar.removeItem(at: index) }
    }

    private func installFullScreenShortcut() {
        // Intercept before the virtual display's responder consumes key equivalents.
        // Limit interception to this VM window; Escape remains available to the guest.
        fullScreenKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window,
                  event.keyCode == 3,
                  event.modifierFlags.intersection([.control, .command, .option, .shift]) == [.control, .command] else { return event }
            if event.type == .keyDown && !event.isARepeat { self.toggleFullScreen() }
            return nil
        }
    }

    @objc private func toggleFullScreen() {
        guard let window, !fullScreenTransitionInFlight, window.attachedSheet == nil else { return }
        window.toggleFullScreen(nil)
    }

    private func updateFullScreenControls() {
        let isFullScreen = window?.styleMask.contains(.fullScreen) == true
        let title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        fullScreenItem?.label = title
        fullScreenItem?.toolTip = "\(title) · ⌃⌘F"
        fullScreenItem?.image = NSImage(systemSymbolName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: title)
        fullScreenItem?.isEnabled = !fullScreenTransitionInFlight
        fullScreenMenuItem?.title = title
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        // Keep the exit button visible; guest keyboard capture must not trap users.
        proposedOptions.subtracting(.autoHideToolbar)
    }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransitionInFlight = true; updateFullScreenControls() }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenTransitionInFlight = true; updateFullScreenControls() }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenTransitionInFlight = false; updateFullScreenControls() }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenTransitionInFlight = false; updateFullScreenControls() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransitionInFlight = false; updateFullScreenControls() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenTransitionInFlight = false; updateFullScreenControls() }

    private func installMacOS() throws {
        guard let path = record.restoreImagePath, FileManager.default.fileExists(atPath: path) else {
            throw VMError.message("The macOS restore image is missing. Choose an IPSW in machine settings to retry installation.")
        }
        guard let machine else { return }
        installationImageLease = try ImageLease(url: URL(fileURLWithPath: path))
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: URL(fileURLWithPath: path))
        self.installer = installer
        publish(.installing)
        Task { @MainActor in
            do {
                try await installer.install()
                self.installationImageLease = nil
                self.record.installationPending = false
                self.record.restoreImagePath = nil
                try self.record.save(to: self.directory)
                // Restoration runs its own guest, which can still be running when
                // install() returns. End that session before booting the installed OS.
                // Keep the installer retained so its shutdown cannot finish the runner.
                self.publish(.starting)
                machine.delegate = nil
                if machine.state != .stopped {
                    do { try await machine.stop() }
                    catch { if machine.state != .stopped { throw error } }
                }
                // Installer guests omit folder shares. Build the normal guest
                // configuration so Guest Tools are available on its first boot.
                let toolsURL = Bundle.main.resourceURL?.appendingPathComponent("GuestTools", isDirectory: true)
                let configuration = try VMConfigurationFactory.make(record: self.record, directory: self.directory, guestToolsURL: toolsURL)
                let installedMachine = VZVirtualMachine(configuration: configuration)
                installedMachine.delegate = self
                self.machine = installedMachine
                (self.window?.contentView as? VZVirtualMachineView)?.virtualMachine = installedMachine
                self.installer = nil
                self.start()
            } catch {
                self.installationImageLease = nil
                self.installer = nil
                self.fail(error)
            }
        }
    }

    private func start() {
        guard let machine else { return }
        // Never issue an invalid running -> running transition.
        if machine.state == .running {
            publish(.running)
            return
        }
        guard machine.canStart else {
            fail(VMError.message("The virtual machine is not ready to start (state: \(machine.state.rawValue))."))
            return
        }
        publish(.starting)
        machine.start { [weak self] result in
            switch result {
            case .success: self?.publish(.running)
            case .failure(let error): self?.fail(error)
            }
        }
    }

    @objc private func togglePause() {
        guard let machine, canTogglePause else { return }
        operationInFlight = true
        updateControls()
        if machine.canPause {
            machine.pause { [weak self] result in
                self?.operationInFlight = false
                switch result {
                case .success: self?.publish(.paused)
                case .failure(let error): self?.report(error)
                }
            }
        } else if machine.canResume {
            machine.resume { [weak self] result in
                self?.operationInFlight = false
                switch result {
                case .success: self?.publish(.running)
                case .failure(let error): self?.report(error)
                }
            }
        } else {
            operationInFlight = false
            updateControls()
        }
    }

    @objc private func shutdown() {
        guard let machine, canShutDown else { return }
        if shutdownWait.isPending || shutdownTimedOut {
            presentShutdownOptions()
            return
        }
        if machine.state == .paused {
            operationInFlight = true
            updateControls()
            machine.resume { [weak self] result in
                self?.operationInFlight = false
                switch result {
                case .success: self?.publish(.running); self?.shutdown()
                case .failure(let error): self?.report(error)
                }
            }
            return
        }
        if record.system == .macOS {
            guestToolsReminder?.suspend()
            operationInFlight = true
            updateControls()
            let client = GuestShutdownClient()
            guestShutdownClient = client
            client.request(on: machine) { [weak self] result in
                guard let self, !self.terminating else { return }
                self.operationInFlight = false
                self.guestShutdownClient = nil
                switch result {
                case .success:
                    self.shutdownWait.begin(at: ProcessInfo.processInfo.systemUptime)
                    self.publish(.stopping)
                case .failure(let error):
                    if error is GuestToolsConnectionError {
                        self.publish(self.livePhase, message: error.localizedDescription)
                        self.guestToolsReminder?.showConnectionFailure(error)
                    } else { self.report(error) }
                }
            }
            return
        }
        do {
            guard machine.canRequestStop else {
                throw VMError.message("The guest cannot shut down yet. Use its power menu, or Force Stop if it is unresponsive.")
            }
            try machine.requestStop()
            shutdownWait.begin(at: ProcessInfo.processInfo.systemUptime)
            publish(.stopping)
        } catch { report(error) }
    }

    @objc private func showGuestTools() {
        guestToolsReminder?.didOpenGuide()
        if guestToolsWindow == nil {
            let toolsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            toolsWindow.title = "Guest Tools"
            toolsWindow.minSize = NSSize(width: 540, height: 500)
            toolsWindow.isReleasedWhenClosed = false
            toolsWindow.contentView = NSHostingView(rootView: ScrollView {
                GuestToolsView().padding(28)
            }.tint(.orange))
            toolsWindow.center()
            guestToolsWindow = toolsWindow
        }
        guestToolsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func confirmForceStop() {
        guard canForceStop, shutdownAlert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Force stop \(record.name)?"
        alert.informativeText = "Unsaved changes inside the virtual machine will be lost."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Force Stop")
        presentShutdownAlert(alert)
    }

    private func presentShutdownOptions() {
        guard !terminating, shutdownAlert == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = shutdownTimedOut ? "\(record.name) hasn’t shut down" : "Waiting for \(record.name) to shut down"
        alert.informativeText = "The guest operating system must respond to the shutdown request. You can shut down from inside the guest, or force it off. Force Stop loses unsaved changes."
        alert.addButton(withTitle: shutdownTimedOut ? "Keep Running" : "Keep Waiting")
        alert.addButton(withTitle: "Force Stop")
        if shutdownTimedOut { alert.addButton(withTitle: "Try Shutdown Again") }
        presentShutdownAlert(alert)
    }

    private func presentShutdownAlert(_ alert: NSAlert) {
        guard let window, window.attachedSheet == nil else { return }
        shutdownAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.shutdownAlert = nil
            if response == .alertSecondButtonReturn, !self.terminating { self.forceStop() }
            else if response == .alertThirdButtonReturn, !self.terminating {
                self.shutdownTimedOut = false
                self.shutdown()
            }
        }
    }

    private func forceStop() {
        guard let machine, canForceStop else { return }
        dismissShutdownAlert()
        shutdownWait.clear()
        shutdownTimedOut = false
        operationInFlight = true
        publish(.stopping)
        machine.stop { [weak self] error in
            guard let self else { return }
            self.operationInFlight = false
            if let error {
                self.publish(self.livePhase)
                self.report(error)
            } else { self.finish() }
        }
    }

    private func poll() {
        guard !terminating else { return }
        if let machine, let result = shutdownWait.check(isStopped: machine.state == .stopped, at: ProcessInfo.processInfo.systemUptime) {
            switch result {
            case .waiting: break
            case .stopped: finish(); return
            case .timedOut:
                shutdownTimedOut = true
                publish(livePhase, message: shutdownTimeoutMessage)
                if window?.isVisible == true { presentShutdownOptions() }
            }
        }
        if phase == .installing { publish(.installing, progress: installer?.progress.fractionCompleted) }
        if let machine {
            guestToolsReminder?.poll(machine: machine, system: record.system, phase: phase,
                                     restoring: installer != nil,
                                     busy: operationInFlight || shutdownWait.isPending,
                                     requireClipboard: record.clipboardSharingEnabled == true)
            if record.system == .macOS {
                clipboardController.poll(machine: machine, enabled: record.clipboardSharingEnabled == true,
                                         window: window, running: phase == .running && !operationInFlight && !shutdownWait.isPending)
            }
        }
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
        self.phase = phase
        lastMessage = message ?? (shutdownTimedOut ? shutdownTimeoutMessage : nil)
        let status = RuntimeStatus(phase: phase, session: session, progress: progress, message: lastMessage)
        try? status.save(to: directory)
        window?.subtitle = phase == .installing ? "Installing macOS · \(Int((progress ?? 0) * 100))%" : phase.title
        if shutdownWait.isPending { window?.subtitle = "Waiting for guest to shut down…" }
        else if shutdownTimedOut { window?.subtitle = "Shutdown timed out · \(phase.title)" }
        pauseItem?.image = NSImage(systemSymbolName: phase == .paused ? "play" : "pause", accessibilityDescription: phase == .paused ? "Resume" : "Pause")
        pauseItem?.label = phase == .paused ? "Resume" : "Pause"
        updateControls()
    }

    private var canTogglePause: Bool {
        installer == nil && !terminating && !operationInFlight && (phase == .running || phase == .paused)
    }
    private var livePhase: RuntimePhase {
        switch machine?.state {
        case .running: return .running
        case .paused: return .paused
        case .stopped: return .stopped
        default: return phase
        }
    }
    private var canShutDown: Bool {
        installer == nil && !terminating && !operationInFlight && (canTogglePause || shutdownWait.isPending)
    }
    private var canForceStop: Bool {
        installer == nil && !terminating && !operationInFlight && machine?.canStop == true
    }
    private func updateControls() {
        pauseItem?.isEnabled = canTogglePause
        stopItem?.isEnabled = canShutDown
        stopItem?.label = shutdownWait.isPending || shutdownTimedOut ? "Shutdown Options…" : "Shut Down"
        stopItem?.toolTip = shutdownWait.isPending || shutdownTimedOut ? "Show options for the pending shutdown" : "Ask the guest operating system to shut down"
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFullScreen): return !fullScreenTransitionInFlight && window?.attachedSheet == nil
        case #selector(togglePause): return canTogglePause
        case #selector(shutdown): return canShutDown
        case #selector(confirmForceStop): return canForceStop
        default: return true
        }
    }
    private func dismissShutdownAlert() {
        if let alert = shutdownAlert { window?.endSheet(alert.window, returnCode: .cancel) }
        shutdownAlert = nil
    }

    private func report(_ error: Error) {
        publish(phase, message: error.localizedDescription)
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func fail(_ error: Error) {
        guestToolsReminder?.suspend()
        shutdownWait.clear()
        shutdownTimedOut = false
        dismissShutdownAlert()
        // Never overwrite the status of a different runner that owns the lock.
        if lock != nil { publish(.failed, message: error.localizedDescription) }
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
        terminating = true
        NSApp.terminate(nil)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard virtualMachine === machine else { return }
        if installer == nil { finish() }
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard virtualMachine === machine else { return }
        fail(error)
    }
    private func finish() {
        guard !terminating else { return }
        terminating = true
        guestToolsReminder?.suspend()
        shutdownWait.clear()
        shutdownTimedOut = false
        dismissShutdownAlert()
        publish(.stopped)
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
    func applicationWillTerminate(_ notification: Notification) {
        guestToolsReminder?.suspend()
        if let fullScreenKeyMonitor { NSEvent.removeMonitor(fullScreenKeyMonitor) }
        timer?.invalidate()
        lock = nil
    }
}
