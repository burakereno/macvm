import SwiftUI
import MacVMCore
import MacVMUI

struct MachineRow: View {
    let entry: VMEntry
    @Bindable var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var showSetupLog = false
    private var phase: RuntimePhase { library.phase(for: entry) }
    private var selected: Bool { library.selectedID == entry.id }
    private var inUse: Bool { library.isInUse(entry) }
    private var statusColor: Color {
        switch phase {
        case .running: .green
        case .paused: .orange
        case .starting, .installing, .provisioning, .stopping: .blue
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                GuestBrandIcon(brand: entry.record.displayBrand)
                    .frame(width: 34, height: 36)
                    .frame(width: 42, height: 45)
                Circle().fill(statusColor).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.background, lineWidth: 2)).offset(x: 2, y: 1)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.record.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if phase.isActive || phase == .failed {
                        Text(phase.title).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(statusColor.opacity(0.09), in: Capsule())
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if [.installing, .provisioning].contains(phase), let progress = library.statuses[entry.id]?.progress {
                    ProgressView(value: progress).frame(maxWidth: 220).controlSize(.mini)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if library.busyIDs.contains(entry.id) || [.starting, .installing, .stopping].contains(phase) {
                ProgressView().controlSize(.small).frame(width: 34)
            } else {
                Button { library.primaryAction(entry) } label: {
                    Image(systemName: [.running, .provisioning].contains(phase) ? "pause.circle" : "play")
                        .font(.system(size: 21, weight: .regular)).frame(width: 34, height: 34)
                }.buttonStyle(.plain)
                    .help([.running, .provisioning].contains(phase) ? "Pause machine" : phase == .paused ? "Resume machine" : "Start machine")
                    .accessibilityLabel([.running, .provisioning].contains(phase) ? "Pause \(entry.record.name)" : "Start or resume \(entry.record.name)")
            }
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 28, height: 34)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(entry.record.name)")
        }
        .padding(.horizontal, 23).padding(.vertical, 17)
        .background {
            if selected { RoundedRectangle(cornerRadius: 27).fill(.regularMaterial).overlay(RoundedRectangle(cornerRadius: 27).stroke(.primary.opacity(0.09))) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 27))
        .onTapGesture(count: 2) { library.start(entry) }
        .onTapGesture { library.selectedID = entry.id }
        .contextMenu { actions }
        .sheet(isPresented: $showSetupLog) { UbuntuSetupLogView(directory: entry.url) }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if library.busyIDs.contains(entry.id) { return "Working with this machine…" }
        if (phase.isActive || phase == .failed), let message = library.statuses[entry.id]?.message { return message }
        if phase == .stopping { return "Waiting for the guest to shut down…" }
        let used = ByteCountFormatter.string(fromByteCount: VMStorage.allocatedBytes(at: entry.url.appendingPathComponent(entry.record.system.diskFilename)), countStyle: .file)
        return "\(entry.record.cpuCount) CPU · \(entry.record.memoryGB) GB RAM · \(used) of \(entry.record.diskGB) GB · \(entry.record.osVersion ?? entry.record.system.title)"
    }

    @ViewBuilder private var actions: some View {
        Button("Open", systemImage: "macwindow") { library.start(entry) }
        if [.running, .provisioning].contains(phase) { Button("Pause", systemImage: "pause") { library.send(.pause, to: entry) } }
        if phase == .paused { Button("Resume", systemImage: "play") { library.send(.resume, to: entry) } }
        if [.running, .provisioning, .paused, .stopping].contains(phase) {
            Button("Shut Down", systemImage: "power") { library.send(.shutdown, to: entry) }
            Button("Force Stop…", systemImage: "stop", role: .destructive) { library.confirmation = .init(entry: entry, kind: .forceStop) }
        }
        Divider()
        if entry.record.ubuntuSetup != nil {
            if inUse && entry.record.ubuntuSetup?.completed == false {
                Button("Retry Ubuntu Setup", systemImage: "arrow.clockwise") { library.send(.retrySetup, to: entry) }
                    .disabled(UbuntuProvisioning.read(record: entry.record, directory: entry.url)?.stage != .failed)
            }
            Button("View Setup Log…", systemImage: "doc.text") {
                showSetupLog = true
            }.disabled(!FileManager.default.fileExists(atPath: UbuntuProvisioning.folder(in: entry.url).appendingPathComponent("Setup.log").path))
        }
        Button("Settings…", systemImage: "slider.horizontal.3") { library.settingsEntry = entry }.disabled(inUse)
        if entry.record.system == .macOS {
            Button("Guest Tools…", systemImage: "shippingbox") { openWindow(id: "guest-tools") }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(entry) }.disabled(entry.record.system == .windows || inUse || entry.record.installationPending || entry.record.ubuntuSetup?.completed == false)
        Menu("Move to Location", systemImage: "folder") {
            ForEach(library.locations) { location in
                Button(location.name) { library.move(entry, to: location) }
                    .disabled(entry.url.deletingLastPathComponent() == location.url)
            }
        }.disabled(inUse)
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("Move to Trash…", systemImage: "trash", role: .destructive) { library.confirmation = .init(entry: entry, kind: .trash) }.disabled(inUse)
    }
}
