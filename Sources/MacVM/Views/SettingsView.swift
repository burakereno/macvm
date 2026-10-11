import SwiftUI
import MacVMCore

private enum SettingsSection: String, CaseIterable, Identifiable {
    case images = "Base Images", locations = "Locations", machines = "Virtual Machines", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .images: "square.3.layers.3d"; case .locations: "externaldrive.fill"; case .machines: "macwindow"; case .about: "info.circle.fill" }
    }
    var color: Color {
        switch self { case .images: .gray; case .locations: .indigo; case .machines: .cyan; case .about: .blue }
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
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text((selection ?? .locations).rawValue).font(.system(size: 23, weight: .semibold))
                    switch selection ?? .locations {
                    case .locations: locationsContent
                    case .images: imagesContent
                    case .machines: defaultsContent
                    case .about: aboutContent
                    }
                    Spacer(minLength: 20)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 840, height: 570)
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
            let images = cachedImages
            if images.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 35)).foregroundStyle(.secondary)
                    Text("A home for your installers").font(.system(size: 16, weight: .semibold))
                    Text("macOS images downloaded from Apple appear here.\nReuse them to create another machine without downloading again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
                }.frame(maxWidth: .infinity).padding(.vertical, 38).settingsCard()
            } else {
                ForEach(images, id: \.path) { url in
                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").foregroundStyle(.green).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).fontWeight(.medium)
                            Text(shortPath(url.deletingLastPathComponent().path)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.padding(17).settingsCard()
                }
            }
            Text("Local IPSW files stay where you selected them. Linux installers are copied into each machine’s package.")
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

    private var cachedImages: [URL] {
        library.locations.flatMap { location in
            ((try? FileManager.default.contentsOfDirectory(at: location.url.appendingPathComponent("Base Images"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "ipsw" }
        }
    }
    private func shortPath(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
}

private extension View {
    func settingsCard() -> some View { background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 15)) }
}
