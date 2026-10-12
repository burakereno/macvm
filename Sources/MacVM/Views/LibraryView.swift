import SwiftUI
import MacVMCore

struct LibraryView: View {
    @Bindable var library: LibraryStore
    @State private var search = ""
    @Environment(\.openSettings) private var openSettings
    private var filtered: [VMEntry] {
        library.entries.filter { search.isEmpty || $0.record.name.localizedCaseInsensitiveContains(search) || $0.record.system.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filtered) { entry in
                            MachineRow(entry: entry, library: library)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 18)
                }
                if filtered.isEmpty { ContentUnavailableView.search(text: search) }
            }
            footer
        }
        .frame(minWidth: 740, minHeight: 510)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbar {
            if let notice = library.notice {
                ToolbarItem(placement: .navigation) {
                    Button { library.errorMessage = notice } label: { Label("Library Notice", systemImage: "exclamationmark.circle") }
                        .foregroundStyle(.orange).help("Some machines or locations need attention")
                }
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .help("Settings · ⌘,")
                Button { library.showCreate = true } label: { Label("New Virtual Machine", systemImage: "plus") }
                    .help("New Virtual Machine · ⌘N")
            }
        }
        .modifier(LibrarySearch(isVisible: library.entries.count > 5, text: $search))
        .sheet(isPresented: $library.showCreate) { CreateMachineView(library: library) }
        .sheet(item: $library.settingsEntry) { entry in MachineSettingsView(entry: entry, library: library) }
        .alert("MacVM", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { library.confirmation != nil }, set: { if !$0 { library.confirmation = nil } }), titleVisibility: .visible) {
            if let confirmation = library.confirmation {
                Button(confirmation.kind == .trash ? "Move to Trash" : "Force Stop", role: .destructive) {
                    if confirmation.kind == .trash { library.trash(confirmation.entry) }
                    else { library.send(.forceStop, to: confirmation.entry) }
                    library.confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { library.confirmation = nil }
        } message: {
            Text(library.confirmation?.kind == .trash ? "The machine and its virtual disk will move to the Trash." : "Unsaved changes inside the virtual machine will be lost.")
        }
    }

    private var confirmationTitle: String {
        guard let item = library.confirmation else { return "" }
        return item.kind == .trash ? "Move \(item.entry.record.name) to the Trash?" : "Force stop \(item.entry.record.name)?"
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)
            HStack(spacing: -14) {
                systemTile("apple.logo", color: .green, rotation: -8, offset: -5)
                systemTile("terminal", color: .orange, rotation: 8, offset: 5)
            }.padding(.bottom, 8)
            VStack(spacing: 9) {
                Text("A little room for another world.")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Run macOS and Linux in a space of their own.\nYour machines, right at home on your Mac.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            Button { library.showCreate = true } label: {
                Label("Create a Virtual Machine", systemImage: "plus").padding(.horizontal, 6)
            }.buttonStyle(.glassProminent).controlSize(.large)
            Button("Add an existing machine…") { library.importMachine() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func systemTile(_ symbol: String, color: Color, rotation: Double, offset: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 39, weight: .medium)).foregroundStyle(color)
            .frame(width: 94, height: 100)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.07)))
            .rotationEffect(.degrees(rotation)).offset(y: offset)
            .shadow(color: .black.opacity(0.06), radius: 15, y: 8)
            .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 11))
            Text("Apple silicon")
            Text("·")
            Text("\(ProcessInfo.processInfo.activeProcessorCount) cores · \(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) GB memory")
            Spacer()
            Text(library.entries.isEmpty ? "Ready when you are" : "\(library.entries.count) \(library.entries.count == 1 ? "machine" : "machines") · \(library.entries.filter { library.phase(for: $0).isActive }.count) active")
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
        .padding(.horizontal, 25).padding(.bottom, 17).padding(.top, 10)
    }
}

private struct LibrarySearch: ViewModifier {
    let isVisible: Bool
    @Binding var text: String
    @ViewBuilder func body(content: Content) -> some View {
        if isVisible { content.searchable(text: $text, placement: .toolbar, prompt: "Find a machine") }
        else { content.onAppear { text = "" } }
    }
}
