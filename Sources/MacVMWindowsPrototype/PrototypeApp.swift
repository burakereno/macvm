import AppKit
import SwiftUI
import WindowsPrototypeCore
import MacVMUI

final class PrototypeModel: ObservableObject {
    @Published var phase = "Stopped"
    @Published var message = "Local Windows ARM engine validation."
    @Published var config: WindowsConfiguration
    let session = WindowsSession()
    var active: Bool { !["Stopped", "Failed"].contains(phase) }
    init() {
        let path = ProcessInfo.processInfo.environment["MACVM_WINDOWS_DIRECTORY"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacVM/Windows Prototypes/Windows 11 ARM").path
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do { config = try WindowsConfiguration.load(directory: directory) }
        catch { config = WindowsConfiguration(directory: directory); message = "Cannot load prototype configuration: \(error.localizedDescription)" }
        if let resources = Bundle.main.resourceURL {
            let helper = resources.appendingPathComponent("Helpers/Windows Display.app/Contents/MacOS/MacVMWindowsDisplay")
            if FileManager.default.isExecutableFile(atPath: helper.path) { config.qemuPath = helper.path }
        }
    }
    func start() {
        session.start(config) { [weak self] phase, message in self?.phase = phase; self?.message = message }
    }
    func detach() {
        guard !active else { return }
        do { config.installerPath = nil; config.toolsPath = nil; try config.save(); message = "Installation media detached. Next boot uses the installed disk." }
        catch { message = error.localizedDescription }
    }
    func forceStop() {
        let alert = NSAlert(); alert.messageText = "Force stop Windows?"
        alert.informativeText = "Unsaved work may be lost. Use Shut Down when Windows responds."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Force Stop")
        if alert.runModal() == .alertSecondButtonReturn { session.perform(.forceStop) }
    }
}

struct PrototypeView: View {
    @ObservedObject var model: PrototypeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                GuestBrandIcon(brand: .windows).frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.config.name).font(.title2.bold())
                    Text("\(model.config.cpuCount) CPU · \(model.config.memoryGB) GB RAM · \(model.config.diskGB) GB disk").foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.phase).font(.headline).foregroundStyle(model.phase == "Failed" || model.phase == "Error" ? .red : .secondary)
            }
            Text(model.message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack {
                Button("Start", action: model.start).disabled(model.active).keyboardShortcut(.return)
                Button(model.phase == "Paused" ? "Resume" : "Pause") { model.session.perform(model.phase == "Paused" ? .resume : .pause) }.disabled(!model.active || model.phase == "Stopping")
                Button("Shut Down") { model.session.perform(.shutdown) }.disabled(!model.active || model.phase == "Stopping")
                Spacer()
                Button("Force Stop…", action: model.forceStop).disabled(!model.active)
            }
            Divider()
            HStack {
                Button("Show VM Files") { NSWorkspace.shared.open(model.config.directory) }
                Button("Detach Installation Media", action: model.detach).disabled(model.active || (model.config.installerPath == nil && model.config.toolsPath == nil))
            }
            Text("Prototype: native QEMU display. Use its View menu to enter and leave full screen. Engine integration into the main MacVM library follows after validation.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 670)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = PrototypeModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Windows Prototype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 726, height: 330), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacVM — Windows ARM Prototype"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PrototypeView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["MACVM_WINDOWS_AUTOSTART"] == "1" || CommandLine.arguments.contains("--autostart") { model.start() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.active {
            let alert = NSAlert(); alert.messageText = "Shut down Windows before quitting."
            alert.informativeText = "The prototype controller stays open while the virtual machine is running."
            alert.addButton(withTitle: "OK"); alert.runModal(); return .terminateCancel
        }
        return .terminateNow
    }
}

let application = NSApplication.shared
let delegate = AppDelegate(); application.delegate = delegate
application.run()
