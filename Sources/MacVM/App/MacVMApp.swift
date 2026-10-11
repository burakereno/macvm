import SwiftUI
import MacVMCore

@main
struct MacVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = LibraryStore()

    var body: some Scene {
        Window("MacVM", id: "library") {
            LibraryView(library: library)
                .tint(.orange)
                .onOpenURL { library.importMachine(at: $0) }
        }
        .defaultSize(width: 900, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
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
                Button("Refresh Library") { library.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(library: library).tint(.orange)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
