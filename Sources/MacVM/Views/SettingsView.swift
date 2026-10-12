import SwiftUI
import MacVMCore
import MacVMUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case images = "Installation Files", locations = "Locations", machines = "Virtual Machines", guestTools = "Guest Tools", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .images: "square.3.layers.3d"; case .locations: "externaldrive.fill"; case .machines: "macwindow"; case .guestTools: "shippingbox.fill"; case .about: "info.circle.fill" }
    }
    var color: Color {
        switch self { case .images: .gray; case .locations: .indigo; case .machines: .cyan; case .guestTools: .orange; case .about: .blue }
    }
}

struct SettingsView: View {
    @Bindable var library: LibraryStore
    @State private var selection: SettingsSection? = .locations
    @AppStorage("defaultCPU") private var defaultCPU = 4
    @AppStorage("defaultMemory") private var defaultMemory = 4
    @AppStorage("defaultNetwork") private var defaultNetwork = true
    @AppStorage("startAfterCreation") private var startAfterCreation = true

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                HStack(spacing: 10) {
                    Image(systemName: section.symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white).frame(width: 27, height: 27)
                        .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 7))
                    Text(section.rawValue)
                }.padding(.vertical, 3).tag(section)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(190)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text((selection ?? .locations).rawValue).font(.system(size: 23, weight: .semibold))
                    switch selection ?? .locations {
                    case .locations: locationsContent
                    case .images: imagesContent
                    case .machines: defaultsContent
                    case .guestTools: GuestToolsView()
                    case .about: aboutContent
                    }
                    Spacer(minLength: 20)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 840, height: 570)
        .alert("Move installer to the Trash?", isPresented: Binding(get: { library.installerToTrash != nil }, set: { if !$0 { library.installerToTrash = nil } })) {
            Button("Cancel", role: .cancel) { library.installerToTrash = nil }
            Button("Move to Trash", role: .destructive) {
                if let file = library.installerToTrash { library.trashInstaller(file) }
                library.installerToTrash = nil
            }
        } message: {
            Text("\(library.installerToTrash?.url.lastPathComponent ?? "") will move to the Trash. Empty the Trash in Finder when you want to reclaim the space. Your virtual disk stays in place.")
        }
        .alert("MacVM", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private var locationsContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(library.locations) { location in
                HStack(spacing: 15) {
                    Image(systemName: "folder.fill").font(.system(size: 27)).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(location.name).font(.system(size: 15, weight: .semibold))
                        Text("\(library.entries.filter { $0.url.deletingLastPathComponent() == location.url }.count) machines · \(shortPath(location.path))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Text(FileManager.default.fileExists(atPath: location.path) ? ByteCountFormatter.string(fromByteCount: Int64(VMStorage.availableBytes(at: location.url)), countStyle: .file) + " available" : "Location is offline")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.open(location.url) }
                        Button("Remove Location", role: .destructive) { library.removeLocation(location) }.disabled(library.locations.count < 2)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }.padding(17).settingsCard()
            }
            Text("Choose where your machines live. Removing a location from this list keeps its files on disk.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 3)
            HStack { Spacer(); Button("Add Location…") { library.addLocation() } }.padding(17).settingsCard().padding(.top, 14)
        }
    }

    private var imagesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            let images = library.installationFiles
            VStack(alignment: .leading, spacing: 8) {
                Text("\(ByteCountFormatter.string(fromByteCount: images.reduce(0) { $0 + $1.bytes }, countStyle: .file)) in installation files").font(.headline)
                Text("New macOS downloads go to Downloads. Remove installers after you finish installing; files still needed by a machine are protected.").font(.callout).foregroundStyle(.secondary)
                Button("Open Downloads", systemImage: "arrow.down.circle") { NSWorkspace.shared.open(InstallationFiles.downloads) }
            }.padding(17).settingsCard()
            if images.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 35)).foregroundStyle(.secondary)
                    Text("A home for your installers").font(.system(size: 16, weight: .semibold))
                    Text("ISO and IPSW files in Downloads and your machine packages appear here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
                }.frame(maxWidth: .infinity).padding(.vertical, 38).settingsCard()
            } else {
                ForEach(images) { file in
                    HStack(spacing: 12) {
                        Image(systemName: file.url.pathExtension.lowercased() == "download" ? "arrow.down.circle" : (file.url.pathExtension.lowercased() == "ipsw" ? "apple.logo" : "opticaldisc")).foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            if file.url.pathExtension == "download" { Text("Paused macOS download · choose Create to resume").font(.caption).foregroundStyle(.secondary) }
                            Text("\(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)) · \(file.machineName ?? shortPath(file.url.deletingLastPathComponent().path))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let blocker = file.blocker { Text(blocker).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Button("Move to Trash…") { library.installerToTrash = file }.disabled(file.blocker != nil)
                    }.padding(17).settingsCard()
                }
            }
            Text("Linux installers have a copy inside the machine package. Turn off Boot from installer ISO in machine settings, then remove that copy while the machine is shut down. Files outside MacVM’s folders are only listed when you selected them for a machine.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var defaultsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 17) {
                Stepper("CPU cores: \(defaultCPU)", value: $defaultCPU, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                Divider()
                Stepper("Memory: \(defaultMemory) GB", value: $defaultMemory, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) - 2))
                Divider()
                Toggle("Connect new machines to the internet", isOn: $defaultNetwork)
                Divider()
                Toggle("Start machines after creation", isOn: $startAfterCreation)
            }.padding(20).settingsCard()
            Text("Defaults apply to new machines. Each machine has its own settings in the library.").font(.system(size: 12)).foregroundStyle(.secondary)
            Label("Running machines keep working when you quit the MacVM library. Shut them down from their windows or the library’s action menu.", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("MacVM").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                        .foregroundStyle(.secondary)
                }
            }
            Text("A little room for another world.").font(.system(size: 16))
            Text("Native virtual machines for Apple silicon. Built with Swift and Apple’s Virtualization framework.")
                .foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            LabeledContent("Supported guests", value: "macOS · ARM64 Linux")
            LabeledContent("Host requirements", value: "Apple silicon · macOS 26+")
            LabeledContent("Created by", value: "Burak Erenoğlu")
            Text("MacVM 0.1 does not include Windows, snapshots, shared clipboard, or automated guest accounts.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
        }.padding(24).settingsCard()
    }

    private func shortPath(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
}

private extension View {
    func settingsCard() -> some View { background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 15)) }
}
