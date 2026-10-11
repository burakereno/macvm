import SwiftUI
import UniformTypeIdentifiers
import MacVMCore

struct CreateMachineView: View {
    @Bindable var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var creator = MachineCreator()
    @State private var name = "macOS"
    @State private var system: GuestSystem = .macOS
    @State private var downloadMacOS = true
    @State private var imageURL: URL?
    @State private var locationID: UUID?
    @State private var cpu = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memory = 4
    @State private var disk = 64
    @State private var network = true
    @AppStorage("defaultCPU") private var defaultCPU = 4
    @AppStorage("defaultMemory") private var defaultMemory = 4
    @AppStorage("defaultNetwork") private var defaultNetwork = true
    @AppStorage("startAfterCreation") private var startAfterCreation = true
    private var location: StorageLocation? { library.locations.first { $0.id == locationID } ?? library.locations.first }
    private var requiredGB: Int { system == .macOS ? (downloadMacOS ? 90 : 64) : 12 }
    private var available: UInt64 { location.map { VMStorage.availableBytes(at: $0.url) } ?? 0 }
    private var spaceOK: Bool { available >= UInt64(requiredGB) * VMStorage.gib }
    private var canCreate: Bool {
        !creator.isWorking && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 && location != nil && spaceOK && ((system == .macOS && downloadMacOS) || imageURL != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("New Virtual Machine").font(.system(size: 22, weight: .semibold))
                Text("A fresh start, in its own space.").foregroundStyle(.secondary).font(.system(size: 12))
            }.padding(.top, 28).padding(.bottom, 20)
            Form {
                Section {
                    TextField("Name", text: $name).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    Picker("System", selection: $system) {
                        Label("macOS", systemImage: "apple.logo").tag(GuestSystem.macOS)
                        Label("Linux · ARM64", systemImage: "terminal").tag(GuestSystem.linux)
                    }
                    if system == .macOS {
                        Picker("Install from", selection: $downloadMacOS) {
                            Text("Download from Apple").tag(true)
                            Text("Local IPSW file").tag(false)
                        }
                    }
                    if system == .linux || !downloadMacOS {
                        LabeledContent(system == .macOS ? "Restore image" : "ARM64 ISO") {
                            Button { selectImage() } label: {
                                Text(imageURL?.lastPathComponent ?? "Choose File…").lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                            }
                        }
                    }
                    Picker("Location", selection: $locationID) {
                        ForEach(library.locations) { location in Text(location.name).tag(Optional(location.id)) }
                    }
                    LabeledContent("Available space") {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)).foregroundStyle(spaceOK ? Color.secondary : .red)
                        Button("Add Location…") { library.addLocation(); locationID = library.locations.last?.id }
                    }
                }
                Section {
                    Stepper(value: $cpu, in: 1...ProcessInfo.processInfo.activeProcessorCount) {
                        LabeledContent("CPU cores", value: "\(cpu)")
                    }
                    Stepper(value: $memory, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) - 2)) {
                        LabeledContent("Memory", value: "\(memory) GB")
                    }
                    Picker("Virtual disk", selection: $disk) {
                        ForEach([16, 32, 64, 128, 256, 512, 1024, 2048].filter { $0 >= system.minimumDiskGB }, id: \.self) { size in
                            Text(size >= 1024 ? "\(size / 1024) TB" : "\(size) GB").tag(size)
                        }
                    }
                    Toggle("Internet access", isOn: $network)
                } header: {
                    Text("Hardware")
                } footer: {
                    Text("The disk grows as you use it. CPU and memory can be changed while the machine is shut down.")
                }
                Section {
                    Label(system == .macOS ? "Finish account setup inside macOS after installation." : "Use an ARM64 (aarch64) ISO. Complete Linux installation in the machine, then eject the installer in its settings.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(creator.isWorking)
            VStack(alignment: .leading, spacing: 10) {
                if creator.isWorking {
                    if let progress = creator.progress { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                    Text(creator.stage).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let error = creator.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if !spaceOK {
                    Label("This location needs at least \(requiredGB) GB free\(system == .macOS && downloadMacOS ? " for the download and installation" : " for installation"). Add a location on another drive.", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Add Existing…") { library.importMachine(); dismiss() }.disabled(creator.isWorking)
                    Spacer()
                    Button("Cancel") {
                        if creator.isWorking { creator.cancel() } else { dismiss() }
                    }.keyboardShortcut(.cancelAction)
                    Button(startAfterCreation ? "Create & Start" : "Create") { create() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).disabled(!canCreate)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 12)
        }
        .frame(width: 590, height: 720)
        .interactiveDismissDisabled(creator.isWorking)
        .onAppear {
            locationID = library.locations.first?.id
            cpu = min(max(1, defaultCPU), ProcessInfo.processInfo.activeProcessorCount)
            memory = min(max(2, defaultMemory), max(2, Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) - 2))
            network = defaultNetwork
        }
        .onChange(of: system) { old, new in
            if name == old.title || name.isEmpty { name = new.title }
            imageURL = nil; disk = new == .macOS ? 64 : 32
        }
    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: system == .macOS ? "ipsw" : "iso") ?? .data]
        panel.message = system == .macOS ? "Choose a macOS restore image." : "Choose a Linux ARM64 installation ISO. Intel (x86_64) images cannot run on Apple silicon."
        if panel.runModal() == .OK { imageURL = panel.url }
    }

    private func create() {
        guard let location else { return }
        var record = VirtualMachineRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines), system: system, cpuCount: cpu, memoryGB: memory, diskGB: disk)
        record.networkEnabled = network
        creator.create(record: record, location: location.url, imageURL: imageURL, downloadMacOS: downloadMacOS) { entry in
            library.refresh(); library.selectedID = entry.id
            dismiss()
            if startAfterCreation { library.start(entry) }
        }
    }
}
