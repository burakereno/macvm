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
                    LabeledContent("Space on this Mac", value: ByteCountFormatter.string(fromByteCount: VMStorage.allocatedBytes(at: entry.url.appendingPathComponent("Disk.img")), countStyle: .file))
                    Toggle("Internet access (NAT)", isOn: $record.networkEnabled)
                }
                if record.system == .linux {
                    Section {
                        Toggle("Boot from installer ISO", isOn: $record.bootFromInstaller)
                    } footer: {
                        Text("After installing Linux, shut down the machine and turn this off to boot from its virtual disk.")
                    }
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
}
