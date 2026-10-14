import SwiftUI
import UniformTypeIdentifiers
import MacVMCore
import WindowsPrototypeCore

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
    @State private var automaticUbuntu = true
    @State private var release: UbuntuRelease = .resolute
    @State private var profile: UbuntuProfile = .gnome
    @State private var username = NSUserName().lowercased()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var developmentTools = false
    @State private var sshPublicKey = ""
    @State private var shareClipboard = false
    @State private var downloadWindows = false
    @State private var windowsDownloadLink = ""
    @State private var windowsChecksum = ""
    @AppStorage("defaultCPU") private var defaultCPU = 4
    @AppStorage("defaultMemory") private var defaultMemory = 4
    @AppStorage("defaultNetwork") private var defaultNetwork = true
    @AppStorage("startAfterCreation") private var startAfterCreation = true
    private var location: StorageLocation? { library.locations.first { $0.id == locationID } ?? library.locations.first }
    private var available: UInt64 { location.map { VMStorage.availableBytes(at: $0.url) } ?? 0 }
    private var isAutomatic: Bool { system == .linux && automaticUbuntu }
    private var setup: UbuntuSetup { UbuntuSetup(release: release, profile: profile, username: username, developmentTools: developmentTools) }
    private var spaceProblem: String? { location.flatMap {
        system == .windows ? WindowsMachinePreparation.spaceProblem(location: $0.url) : isAutomatic ? UbuntuMachinePreparation.spaceProblem(setup: setup, location: $0.url)
                    : InstallationSpace.problem(system: system, downloading: system == .macOS && downloadMacOS, location: $0.url)
    } }
    private var accountProblem: String? {
        guard isAutomatic else { return nil }
        do {
            try UbuntuSetup.validateUsername(username)
            try UbuntuSetup.validatePassword(password, confirmation: confirmation)
            try UbuntuSetup.validatePublicKey(sshPublicKey.isEmpty ? nil : sshPublicKey)
            guard network else { return "Internet access is required for automatic setup." }
            return nil
        } catch { return error.localizedDescription }
    }
    private var spaceOK: Bool { location != nil && spaceProblem == nil }
    private var canCreate: Bool {
        !creator.isWorking && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 && location != nil && spaceOK && accountProblem == nil && sourceReady
    }
    private var sourceReady: Bool {
        if system == .windows { return downloadWindows ? validWindowsLink : imageURL != nil }
        return isAutomatic || (system == .macOS && downloadMacOS) || imageURL != nil
    }
    private var validWindowsLink: Bool {
        guard let url = URL(string: windowsDownloadLink) else { return false }
        return (try? WindowsMachinePreparation.validateDownloadURL(url)) != nil
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
                        Label("Windows 11 · ARM64", systemImage: "square.grid.2x2.fill").tag(GuestSystem.windows)
                    }
                    if system == .macOS {
                        Picker("Install from", selection: $downloadMacOS) {
                            Text("Download from Apple").tag(true)
                            Text("Local IPSW file").tag(false)
                        }
                        if downloadMacOS { LabeledContent("Download folder", value: "Downloads") }
                    }
                    if system == .linux {
                        Picker("Installation", selection: $automaticUbuntu) {
                            Text("Automatic Ubuntu").tag(true)
                            Text("Manual · ARM64 ISO").tag(false)
                        }
                    }
                    if system == .windows {
                        Picker("Install from", selection: $downloadWindows) {
                            Text("Local ARM64 ISO").tag(false)
                            Text("Microsoft download link").tag(true)
                        }
                        Button("Get Windows from Microsoft…") { NSWorkspace.shared.open(WindowsMachinePreparation.downloadPage) }
                        if downloadWindows {
                            TextField("ISO download link", text: $windowsDownloadLink).autocorrectionDisabled()
                            Text("Choose ARM64 and your language on Microsoft's page, then paste its ISO link. Links expire after 24 hours. MacVM downloads to Downloads.").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Verify checksum (optional)") {
                            TextField("Microsoft SHA-256", text: $windowsChecksum).autocorrectionDisabled().font(.caption)
                        }
                    }
                    if isAutomatic {
                        Picker("Ubuntu version", selection: $release) {
                            ForEach(UbuntuRelease.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Profile", selection: $profile) {
                            ForEach(UbuntuProfile.allCases) { Text($0.title).tag($0) }
                        }
                        Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Download folder", value: "Downloads")
                    }
                    if (system == .linux && !automaticUbuntu) || (system == .macOS && !downloadMacOS) || (system == .windows && !downloadWindows) {
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
                if isAutomatic {
                    Section {
                        TextField("User name", text: $username).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        SecureField("Confirm password", text: $confirmation)
                        Text("Use at least 8 characters. Both password fields must match.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Development tools", isOn: $developmentTools)
                        Text("Git, build tools, Python, Node.js and Docker. Administrative commands still require your password.")
                            .font(.caption).foregroundStyle(.secondary)
                        if profile.desktop { Toggle("Share clipboard", isOn: $shareClipboard) }
                        DisclosureGroup("SSH public key (optional)") {
                            TextField("ssh-ed25519 …", text: $sshPublicKey).font(.caption).autocorrectionDisabled()
                            Button("Choose Public Key…") { selectPublicKey() }
                            Text("Key-based SSH only. The password is for console login and sudo. Private keys stay on your Mac.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Account")
                    } footer: {
                        Text("Ubuntu creates this account on first boot. Your password is hashed locally and is not saved in machine settings.")
                    }
                }
                Section {
                    Stepper(value: $cpu, in: (system == .windows ? 2 : 1)...min(system == .windows ? 16 : 512, ProcessInfo.processInfo.activeProcessorCount)) {
                        LabeledContent("CPU cores", value: "\(cpu)")
                    }
                    Stepper(value: $memory, in: (system == .windows ? 4 : isAutomatic ? profile.minimumMemoryGB : 2)...max(4, Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) - 2)) {
                        LabeledContent("Memory", value: "\(memory) GB")
                    }
                    Picker("Virtual disk", selection: $disk) {
                        ForEach([16, 32, 64, 128, 256, 512, 1024, 2048].filter { $0 >= (isAutomatic ? profile.minimumDiskGB : system.minimumDiskGB) && (system != .windows || $0 <= 512) }, id: \.self) { size in
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
                    Label(system == .windows ? "Complete Windows Setup inside the VM. The MacVM Tools CD includes its network driver and integration tools. After installation, shut down and eject the installer in Machine Settings. A Windows licence is required for activation." : system == .macOS ? "Finish account setup inside macOS after installation." : isAutomatic ? "The official ARM64 cloud image boots directly. MacVM installs your profile in the VM and shows setup progress. Desktop profiles download additional packages; keep Internet access enabled." : "Use an ARM64 (aarch64) ISO. Complete Linux installation in the machine, then eject the installer in its settings.", systemImage: "info.circle")
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
                    Label(spaceProblem ?? "Choose a storage location.", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if let problem = accountProblem, !password.isEmpty || !confirmation.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
            if name == old.title || name.hasPrefix("Ubuntu ") || name.isEmpty { name = new == .linux && automaticUbuntu ? release.title : new.title }
            imageURL = nil; disk = new == .windows ? 128 : new == .macOS ? 64 : 32
            if new == .windows { cpu = max(2, min(16, cpu)); memory = max(8, memory) }
            if isAutomatic { memory = max(memory, profile.minimumMemoryGB); network = true }
        }
        .onChange(of: profile) { _, new in memory = max(memory, new.minimumMemoryGB); disk = max(disk, new.minimumDiskGB) }
        .onChange(of: release) { old, new in if name == old.title { name = new.title } }
        .onChange(of: automaticUbuntu) { _, new in
            if new { name = release.title; network = true; memory = max(memory, profile.minimumMemoryGB); disk = max(disk, profile.minimumDiskGB) }
        }
    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.directoryURL = InstallationFiles.downloads
        panel.allowedContentTypes = [UTType(filenameExtension: system == .macOS ? "ipsw" : "iso") ?? .data]
        panel.message = system == .windows ? "Choose the Windows 11 ARM64 ISO from Downloads. Intel/x64 media cannot run here." : system == .macOS ? "Choose a macOS restore image." : "Choose a Linux ARM64 installation ISO. Intel (x86_64) images cannot run on Apple silicon."
        if panel.runModal() == .OK { imageURL = panel.url }
    }

    private func create() {
        guard let location else { return }
        var record = VirtualMachineRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines), system: system, cpuCount: cpu, memoryGB: memory, diskGB: disk)
        record.networkEnabled = network
        let completion: (VMEntry) -> Void = { entry in
            library.refresh(); library.selectedID = entry.id
            dismiss()
            if startAfterCreation { library.start(entry) }
        }
        if system == .windows {
            creator.createWindows(record: record, location: location.url, imageURL: imageURL,
                downloadURL: downloadWindows ? URL(string: windowsDownloadLink) : nil,
                checksum: windowsChecksum.trimmingCharacters(in: .whitespacesAndNewlines), completion: completion)
        } else if isAutomatic {
            record.ubuntuSetup = setup
            record.clipboardSharingEnabled = profile.desktop && shareClipboard
            creator.createUbuntu(record: record, location: location.url, password: password,
                                 sshPublicKey: sshPublicKey.isEmpty ? nil : sshPublicKey, completion: completion)
            password = ""; confirmation = ""
        } else {
            creator.create(record: record, location: location.url, imageURL: imageURL, downloadMacOS: downloadMacOS, completion: completion)
        }
    }

    private func selectPublicKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pub") ?? .data]
        panel.message = "Choose an SSH public key (.pub). Private keys must stay on this Mac."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size > 0, size <= 8192 else { throw VMError.message("Choose an SSH public key up to 8 KB.") }
                let key = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                try UbuntuSetup.validatePublicKey(key); sshPublicKey = key
            } catch { creator.errorMessage = error.localizedDescription }
        }
    }
}
