import SwiftUI
import UniformTypeIdentifiers
import MacVMCore

struct MachineSettingsView: View {
    let entry: VMEntry
    @Bindable var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: VirtualMachineRecord
    @State private var errorMessage: String?

    init(entry: VMEntry, library: LibraryStore) {
        self.entry = entry; self.library = library
        _record = State(initialValue: entry.record)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Machine Settings").font(.system(size: 22, weight: .semibold)).padding(.top, 25)
            Form {
                Section {
                    TextField("Name", text: $record.name)
                    LabeledContent("System", value: record.osVersion ?? record.system.title)
                }
                Section("Hardware") {
                    Stepper("CPU cores: \(record.cpuCount)", value: $record.cpuCount, in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("Memory: \(record.memoryGB) GB", value: $record.memoryGB, in: 2...max(2, Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) - 2))
                    LabeledContent("Disk capacity", value: "\(record.diskGB) GB")
                    LabeledContent("Space on this Mac", value: ByteCountFormatter.string(fromByteCount: VMStorage.allocatedBytes(at: entry.url.appendingPathComponent(entry.record.system.diskFilename)), countStyle: .file))
                    Toggle("Internet access (NAT)", isOn: $record.networkEnabled)
                    if record.system == .windows { Toggle("Sound output", isOn: Binding(get: { record.audioEnabled ?? true }, set: { record.audioEnabled = $0 })) }
                }
                if let setup = record.ubuntuSetup {
                    Section("Ubuntu setup") {
                        LabeledContent("Profile", value: setup.profile.title)
                        LabeledContent("Account", value: setup.username)
                        LabeledContent("Setup", value: setup.completed ? "Completed" : "Completes on first boot")
                    }
                } else if record.system == .linux || record.system == .windows {
                    Section {
                        Toggle("Boot from installer ISO", isOn: Binding(get: { record.bootFromInstaller }, set: { value in
                            record.bootFromInstaller = value
                            if record.system == .windows && !value { record.windowsInstallationPending = false }
                        }))
                        if record.system == .windows {
                            Toggle("Automatic display resolution", isOn: Binding(get: {
                                record.windowsAutomaticDisplay ?? !record.bootFromInstaller
                            }, set: { record.windowsAutomaticDisplay = $0 }))
                            Text("Install Windows Tools first. Then shut down Windows, enable automatic display resolution and start it again. Turn this off to recover a blank screen; the setup display also works without an ISO.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("After installing \(record.system.title), shut down the machine and turn this off to boot from its virtual disk. Remove unused ISO files in Settings → Installation Files.")
                    }
                }
                Section("Sharing") {
                    Toggle("Share clipboard", isOn: Binding(get: { record.clipboardSharingEnabled == true }, set: { record.clipboardSharingEnabled = $0 }))
                    Text(record.system == .windows ? "Text clipboard and shared folders require Windows Tools. In the running VM, choose Virtual Machine → Install Windows Tools. Only the active VM window shares your clipboard." : record.system == .macOS ? "Text clipboard sharing requires the included Guest Tools. Only the active VM window shares your clipboard." : "Clipboard sharing requires spice-vdagent inside Linux. Ubuntu: sudo apt install spice-vdagent, then sign out and in.").font(.caption).foregroundStyle(.secondary)
                    ForEach(record.sharedFolders ?? []) { folder in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(folder.name).fontWeight(.medium)
                                Spacer()
                                Button("Remove") { record.sharedFolders?.removeAll { $0.id == folder.id } }
                            }
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Toggle("Read only", isOn: Binding(get: { record.sharedFolders?.first(where: { $0.id == folder.id })?.readOnly ?? true }, set: { value in
                                if let index = record.sharedFolders?.firstIndex(where: { $0.id == folder.id }) { record.sharedFolders?[index].readOnly = value }
                            }))
                        }
                    }
                    Button("Add Shared Folder…", action: addSharedFolder).disabled((record.sharedFolders ?? []).count >= 8)
                    Text(verbatim: record.system == .windows ? "In Windows Explorer, enter \\\\localhost@9843\\DavWWWRoot. Windows Tools must be installed. File uploads are limited to 128 MB per file." : record.system == .macOS ? "Shared folders appear in Finder → My Shared Files after starting the machine." : "In Linux, mount the share once: sudo mkdir -p /mnt/macvm; sudo mount -t virtiofs macvm-share /mnt/macvm").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if record.installationPending {
                    Section("macOS installation") {
                        LabeledContent("Restore image") {
                            Button("Locate IPSW…") {
                                let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
                                if panel.runModal() == .OK { record.restoreImagePath = panel.url?.path }
                            }
                        }
                        Text(record.restoreImagePath ?? "Missing image").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        do { try library.update(record, at: entry.url); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(library.isInUse(entry))
                }
            }.padding(.horizontal, 25).padding(.bottom, 22)
        }.frame(width: 550, height: 565)
    }

    private func addSharedFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the folder this machine can access. It starts read-only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !(record.sharedFolders ?? []).contains(where: { $0.path == url.path }) else { return }
        let base = url.lastPathComponent == "MacVM Guest Tools" ? "Shared Folder" : url.lastPathComponent
        var name = base; var count = 2
        while (record.sharedFolders ?? []).contains(where: { $0.name == name }) { name = "\(base) \(count)"; count += 1 }
        record.sharedFolders = (record.sharedFolders ?? []) + [SharedFolder(name: name, path: url.path)]
    }
}
