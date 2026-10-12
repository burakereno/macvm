import SwiftUI
import MacVMUpdate

struct UpdateView: View {
    @Bindable var checker: UpdateChecker
    @Bindable var installer: UpdateInstaller
    @Bindable var library: LibraryStore
    @AppStorage("automaticallyCheckForUpdates") private var automatic = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MacVM Updates").font(.title2.weight(.semibold))
            Text("Installed version: \(checker.currentVersion)").foregroundStyle(.secondary)
            Toggle("Automatically check for updates", isOn: $automatic)
            if let release = checker.release {
                Text("MacVM \(release.manifest.version) is available.").font(.headline)
                Text("Install the verified update and restart MacVM. Shut down your machines first.").font(.callout).foregroundStyle(.secondary)
                Button("Install Update…") {
                    Task { await installer.install(release, machinesAreRunning: { library.entries.contains { library.isInUse($0) } }) }
                }.buttonStyle(.borderedProminent).disabled(installer.isWorking || checker.isChecking)
            } else if checker.checkedSuccessfully && checker.lastError == nil {
                Label("MacVM is up to date", systemImage: "checkmark.circle")
            }
            if installer.isWorking || checker.isChecking {
                HStack { ProgressView().controlSize(.small); Text(installer.isWorking ? installer.stage : "Checking for updates…") }
            }
            if let error = installer.lastError ?? checker.lastError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Button("Check for Updates") { Task { await checker.check(manual: true) } }
                .disabled(checker.isChecking || installer.isWorking)
            Spacer(minLength: 0)
        }.frame(minWidth: 390, minHeight: 240)
    }
}
