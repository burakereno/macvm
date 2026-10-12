import SwiftUI
import MacVMCore
import MacVMUI
import MacVMUpdate

@main
struct MacVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = LibraryStore()
    @State private var updater = UpdateChecker(currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
    @State private var updateInstaller = UpdateInstaller()
    @AppStorage("automaticallyCheckForUpdates") private var automaticallyCheckForUpdates = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MacVM", id: "library") {
            LibraryView(library: library)
                .tint(.orange)
                .onOpenURL { library.importMachine(at: $0) }
                .task {
                    confirmUpdateLaunch()
                    while !Task.isCancelled {
                        if automaticallyCheckForUpdates { await updater.check(manual: false) }
                        try? await Task.sleep(for: .seconds(21_600))
                    }
                }
        }
        .defaultSize(width: 900, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { openWindow(id: "updates"); Task { await updater.check(manual: true) } }
                    .disabled(updater.isChecking || updateInstaller.isWorking)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { library.showCreate = true }.keyboardShortcut("n")
                Button("Add Existing Machine…") { library.importMachine() }.keyboardShortcut("o")
            }
            CommandMenu("Virtual Machine") {
                Button("Start / Pause / Resume") {
                    if let entry = library.entries.first(where: { $0.id == library.selectedID }) { library.primaryAction(entry) }
                }.keyboardShortcut("r").disabled(library.selectedID == nil)
                Button("Show Machine") {
                    if let entry = library.entries.first(where: { $0.id == library.selectedID }) { library.start(entry) }
                }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(library.selectedID == nil)
                Divider()
                Button("Guest Tools…") { openWindow(id: "guest-tools") }
                Button("Refresh Library") { library.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(library: library).tint(.orange)
        }
        Window("MacVM Updates", id: "updates") {
            UpdateView(checker: updater, installer: updateInstaller, library: library)
                .padding(28).tint(.orange)
        }.defaultSize(width: 460, height: 320)
        Window("Guest Tools", id: "guest-tools") {
            ScrollView { GuestToolsView().padding(28) }
                .frame(minWidth: 540, minHeight: 500).tint(.orange)
        }.defaultSize(width: 600, height: 720)
    }
    private func confirmUpdateLaunch() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--macvm-update-confirm"), args.indices.contains(index + 1) {
            let marker = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let directory = marker.deletingLastPathComponent()
            guard marker.lastPathComponent == "started", directory.lastPathComponent.hasPrefix("MacVM-update-"),
                  directory.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return }
            try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: marker, options: .atomic)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
