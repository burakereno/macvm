import SwiftUI
import MacVMCore

struct MachineRow: View {
    let entry: VMEntry
    @Bindable var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    private var phase: RuntimePhase { library.phase(for: entry) }
    private var selected: Bool { library.selectedID == entry.id }
    private var inUse: Bool { library.isInUse(entry) }
    private var statusColor: Color {
        switch phase {
        case .running: .green
        case .paused: .orange
        case .starting, .installing, .stopping: .blue
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: entry.record.system.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(entry.record.system == .macOS ? Color.green : .orange)
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
                if phase == .installing, let progress = library.statuses[entry.id]?.progress {
                    ProgressView(value: progress).frame(maxWidth: 220).controlSize(.mini)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if library.busyIDs.contains(entry.id) || [.starting, .installing, .stopping].contains(phase) {
                ProgressView().controlSize(.small).frame(width: 34)
            } else {
                Button { library.primaryAction(entry) } label: {
                    Image(systemName: phase == .running ? "pause.circle" : "play")
                        .font(.system(size: 21, weight: .regular)).frame(width: 34, height: 34)
                }.buttonStyle(.plain)
                    .help(phase == .running ? "Pause machine" : phase == .paused ? "Resume machine" : "Start machine")
                    .accessibilityLabel(phase == .running ? "Pause \(entry.record.name)" : "Start or resume \(entry.record.name)")
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
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if library.busyIDs.contains(entry.id) { return "Working with this machine…" }
        if (phase.isActive || phase == .failed), let message = library.statuses[entry.id]?.message { return message }
        if phase == .stopping { return "Waiting for the guest to shut down…" }
        let used = ByteCountFormatter.string(fromByteCount: VMStorage.allocatedBytes(at: entry.url.appendingPathComponent("Disk.img")), countStyle: .file)
        return "\(entry.record.cpuCount) CPU · \(entry.record.memoryGB) GB RAM · \(used) of \(entry.record.diskGB) GB · \(entry.record.osVersion ?? entry.record.system.title)"
    }

    @ViewBuilder private var actions: some View {
        Button("Open", systemImage: "macwindow") { library.start(entry) }
        if phase == .running { Button("Pause", systemImage: "pause") { library.send(.pause, to: entry) } }
        if phase == .paused { Button("Resume", systemImage: "play") { library.send(.resume, to: entry) } }
        if [.running, .paused, .stopping].contains(phase) {
            Button("Shut Down", systemImage: "power") { library.send(.shutdown, to: entry) }
            Button("Force Stop…", systemImage: "stop", role: .destructive) { library.confirmation = .init(entry: entry, kind: .forceStop) }
        }
        Divider()
        Button("Settings…", systemImage: "slider.horizontal.3") { library.settingsEntry = entry }.disabled(inUse)
        if entry.record.system == .macOS {
            Button("Guest Tools…", systemImage: "shippingbox") { openWindow(id: "guest-tools") }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(entry) }.disabled(inUse || entry.record.installationPending)
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
