import AppKit
import Observation
import UniformTypeIdentifiers
import MacVMCore

struct StorageLocation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
}

private struct LibraryPreferences: Codable {
    var locations: [StorageLocation]
    var importedPaths: [String] = []
}

@MainActor @Observable
final class LibraryStore {
    var entries: [VMEntry] = []
    var locations: [StorageLocation] = []
    var statuses: [UUID: RuntimeStatus] = [:]
    var busyIDs: Set<UUID> = []
    var errorMessage: String?
    var notice: String?
    var showCreate = false
    var selectedID: UUID?
    var settingsEntry: VMEntry?
    var confirmation: MachineConfirmation?
    var installerToTrash: InstallationFile?
    private var importedPaths: [String] = []
    private var activeIDs: Set<UUID> = []
    private var launching: [UUID: Date] = [:]
    private var timer: Timer?
    let root: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["MACVM_LIBRARY_ROOT"] {
            root = URL(fileURLWithPath: override)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacVM")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let preferences = root.appendingPathComponent("Library.json")
            if FileManager.default.fileExists(atPath: preferences.path) {
                let saved = try JSONDecoder().decode(LibraryPreferences.self, from: Data(contentsOf: preferences))
                locations = saved.locations; importedPaths = saved.importedPaths
            } else {
                let machines = root.appendingPathComponent("Virtual Machines")
                try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
                locations = [StorageLocation(name: "MacVM", path: machines.path)]
                try savePreferences()
            }
            refresh()
        } catch { errorMessage = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var urls: [URL] = importedPaths.map { URL(fileURLWithPath: $0) }
        var issues: [String] = []
        for location in locations {
            guard FileManager.default.fileExists(atPath: location.path) else {
                issues.append("\(location.name) is offline. Reconnect the drive to see its machines.")
                continue
            }
            let children = (try? FileManager.default.contentsOfDirectory(at: location.url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            urls += children.filter { $0.pathExtension == "macvm" }
        }
        var found: [VMEntry] = []
        var seen = Set<UUID>()
        var runtime: [UUID: RuntimeStatus] = [:]
        var active = Set<UUID>()
        for url in Set(urls.map(\.standardizedFileURL)) {
            let record: VirtualMachineRecord
            do { record = try VirtualMachineRecord.load(from: url) }
            catch { issues.append("Could not load \(url.lastPathComponent): \(error.localizedDescription)"); continue }
            guard !seen.contains(record.id) else {
                issues.append("Two packages have the same machine identity. Use Duplicate in MacVM to create independent copies.")
                continue
            }
            seen.insert(record.id)
            found.append(VMEntry(record: record, url: url))
            if record.ubuntuSetup?.completed == true { UbuntuProvisioning.cleanupSeedAfterStop(at: url) }
            if VMLock.isHeld(at: url) { active.insert(record.id) }
            if let status = RuntimeStatus.load(from: url) { runtime[record.id] = status }
        }
        entries = found.sorted { $0.record.createdAt < $1.record.createdAt }
        notice = issues.isEmpty ? nil : issues.joined(separator: "\n\n")
        statuses = runtime; activeIDs = active
        for (id, date) in launching {
            if active.contains(id) { launching.removeValue(forKey: id) }
            else if Date().timeIntervalSince(date) > 20 {
                launching.removeValue(forKey: id)
                errorMessage = "The virtual machine did not start. Try again, or check Console for MacVMRunner."
            }
        }
    }

    func phase(for entry: VMEntry) -> RuntimePhase {
        if launching[entry.id] != nil { return .starting }
        guard activeIDs.contains(entry.id) else { return statuses[entry.id]?.phase == .failed ? .failed : .stopped }
        return statuses[entry.id]?.phase ?? .starting
    }
    func isInUse(_ entry: VMEntry) -> Bool { launching[entry.id] != nil || activeIDs.contains(entry.id) || busyIDs.contains(entry.id) }

    func start(_ entry: VMEntry) {
        if isInUse(entry) { send(.show, to: entry); return }
        do {
            _ = try VMStorage.validateBundle(at: entry.url)
            guard let runner = Bundle.main.url(forResource: "MacVMRunner", withExtension: "app", subdirectory: "Helpers") else {
                throw VMError.message("The VM runner is missing. Reinstall MacVM.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--bundle", entry.url.path]
            launching[entry.id] = Date()
            NSWorkspace.shared.openApplication(at: runner, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error { self?.launching.removeValue(forKey: entry.id); self?.errorMessage = error.localizedDescription }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func send(_ action: RuntimeAction, to entry: VMEntry) {
        guard VMLock.isHeld(at: entry.url), let status = RuntimeStatus.load(from: entry.url) else { return }
        do { try RuntimeCommand(action: action, session: status.session).send(to: entry.url) }
        catch { errorMessage = error.localizedDescription }
    }

    func primaryAction(_ entry: VMEntry) {
        switch phase(for: entry) {
        case .running, .provisioning: send(.pause, to: entry)
        case .paused: send(.resume, to: entry)
        case .stopped, .failed: start(entry)
        default: send(.show, to: entry)
        }
    }

    func update(_ record: VirtualMachineRecord, at url: URL) throws {
        let lock = try VMLock(directory: url)
        defer { withExtendedLifetime(lock) {} }
        try VMStorage.validate(record)
        try record.save(to: url)
        refresh()
    }

    func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Location"; panel.message = "Choose a folder for your virtual machines."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if locations.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return }
        do {
            guard FileManager.default.isWritableFile(atPath: url.path) else { throw VMError.message("This folder is not writable.") }
            locations.append(StorageLocation(name: url.lastPathComponent, path: url.path))
            try savePreferences(); refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func removeLocation(_ location: StorageLocation) {
        guard locations.count > 1 else { return }
        guard !entries.contains(where: { $0.url.deletingLastPathComponent() == location.url && isInUse($0) }) else {
            errorMessage = "Shut down machines in this location before removing it."; return
        }
        locations.removeAll { $0.id == location.id }
        do { try savePreferences(); refresh() } catch { errorMessage = error.localizedDescription }
    }

    func importMachine() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.init(exportedAs: "com.burakerenoglu.macvm.machine", conformingTo: .package)]
        panel.prompt = "Add Machine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importMachine(at: url)
    }

    func importMachine(at url: URL) {
        do {
            var record = try VMStorage.validateBundle(at: url)
            if let existing = entries.first(where: { $0.id == record.id }) {
                guard existing.url.standardizedFileURL == url.standardizedFileURL else {
                    throw VMError.message("A machine with this identity is already in your library. Use Duplicate to make an independent copy.")
                }
                selectedID = existing.id; return
            }
            if record.clipboardSharingEnabled == true || !(record.sharedFolders ?? []).isEmpty {
                let lock = try VMLock(directory: url)
                defer { withExtendedLifetime(lock) {} }
                record = record.withoutHostSharing()
                try record.save(to: url)
                errorMessage = "Sharing was disabled for this imported machine. Choose folders and clipboard access in Machine Settings before enabling them."
            }
            importedPaths.append(url.path)
            try savePreferences(); refresh(); selectedID = record.id
        } catch { errorMessage = error.localizedDescription }
    }

    func duplicate(_ entry: VMEntry) {
        guard !isInUse(entry) else { return }
        busyIDs.insert(entry.id)
        Task {
            do {
                let copy = try await Task.detached(priority: .userInitiated) { try VMStorage.clone(entry, to: entry.url.deletingLastPathComponent()) }.value
                if !locations.contains(where: { $0.url == copy.url.deletingLastPathComponent() }) {
                    importedPaths.append(copy.url.path); try savePreferences()
                }
                refresh(); selectedID = copy.id
            } catch { errorMessage = error.localizedDescription }
            busyIDs.remove(entry.id)
        }
    }

    func move(_ entry: VMEntry, to location: StorageLocation) {
        guard !isInUse(entry), entry.url.deletingLastPathComponent() != location.url else { return }
        busyIDs.insert(entry.id)
        Task {
            do {
                let destination = location.url.appendingPathComponent(entry.url.lastPathComponent)
                try await Task.detached(priority: .userInitiated) {
                    let lock = try VMLock(directory: entry.url)
                    defer { withExtendedLifetime(lock) {} }
                    guard VMStorage.availableBytes(at: location.url) > UInt64(max(0, VMStorage.allocatedBytes(at: entry.url.appendingPathComponent(entry.record.system.diskFilename)))) + VMStorage.gib else {
                        throw VMError.message("There is not enough free space at the destination.")
                    }
                    let staging = location.url.appendingPathComponent(".\(entry.id.uuidString).moving")
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw VMError.message("This location already contains this machine.")
                    }
                    try FileManager.default.moveItem(at: entry.url, to: staging)
                    do { try FileManager.default.moveItem(at: staging, to: destination) }
                    catch {
                        try? FileManager.default.moveItem(at: staging, to: entry.url)
                        throw error
                    }
                }.value
                importedPaths.removeAll { $0 == entry.url.path }
                try savePreferences(); refresh()
            } catch { errorMessage = error.localizedDescription }
            busyIDs.remove(entry.id)
        }
    }

    func trash(_ entry: VMEntry) {
        do {
            let lock = try VMLock(directory: entry.url)
            defer { withExtendedLifetime(lock) {} }
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            importedPaths.removeAll { $0 == entry.url.path }
            try savePreferences(); refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    var installationFiles: [InstallationFile] {
        InstallationFiles.list(legacyCaches: locations.map { $0.url.appendingPathComponent("Base Images") }, entries: entries)
    }

    func trashInstaller(_ file: InstallationFile) {
        do {
            refresh()
            guard notice == nil, locations.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw VMError.message("Reconnect unavailable storage and resolve unreadable machines before removing installation files.")
            }
            try InstallationFiles.moveToTrash(file.url, entries: entries)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func savePreferences() throws {
        let prefs = LibraryPreferences(locations: locations, importedPaths: importedPaths)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prefs).write(to: root.appendingPathComponent("Library.json"), options: .atomic)
    }
}

struct MachineConfirmation: Identifiable {
    enum Kind { case trash, forceStop }
    let id = UUID()
    var entry: VMEntry
    var kind: Kind
}
