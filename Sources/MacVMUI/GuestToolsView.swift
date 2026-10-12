import SwiftUI
import UniformTypeIdentifiers

/// The library and runner show the same instructions and export the same package.
public struct GuestToolsView: View {
    @State private var errorMessage: String?
    @State private var savedURL: URL?

    public init() {}

    private var installerURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let relativePaths = [
            "GuestTools/Install MacVM Guest Tools.pkg",
            "Helpers/MacVMRunner.app/Contents/Resources/GuestTools/Install MacVM Guest Tools.pkg"
        ]
        return relativePaths.map { resources.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                    .frame(width: 56, height: 56)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacVM Guest Tools").font(.title2.weight(.semibold))
                    Text("For macOS virtual machines · Preview")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Included version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Connect your macOS machine to MacVM’s Shut Down button and optional text clipboard sharing. Install the tools inside each macOS virtual machine, and update them when you update MacVM.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 17) {
                instruction(1, "Open your macOS machine", "Start the machine and sign in to its desktop.")
                instruction(2, "Find the included installer", "In the guest’s Finder, open My Shared Files → MacVM Guest Tools.")
                instruction(3, "Install inside the machine", "Open Install MacVM Guest Tools.pkg and enter the guest’s administrator password when asked.")
                instruction(4, "Restart the guest", "Use the guest’s Apple menu to restart after installing or updating the tools.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text("Optional: save a copy").font(.callout.weight(.medium))
                Text("The installer is already available in your guest’s My Shared Files folder. Save a copy only if you want to transfer it yourself. Installation takes place inside the virtual machine.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Save Installer…", systemImage: "square.and.arrow.down", action: saveInstaller)
                    .buttonStyle(.bordered).disabled(installerURL == nil)
                if installerURL == nil {
                    Text("The installer is missing. Reinstall the complete MacVM app to restore it.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let savedURL {
                    HStack {
                        Text("Saved: \(savedURL.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                            .controlSize(.small)
                    }
                }
            }

            DisclosureGroup("Compatibility and troubleshooting") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Requires macOS 26 or later inside an Apple silicon virtual machine. Linux guests do not need this package.")
                    Text("Desktop and login-screen shutdown have been tested on macOS 27.0.1. If MacVM cannot connect, use the guest’s own power menu.")
                    Text("If another user is still signed in, sign in before requesting shutdown so macOS can handle open applications.")
                    Text("If My Shared Files is missing, fully shut down the guest, update MacVM, then start it again. To update the tools, run the included installer again and restart the guest.")
                    Text("MacVM checks the connection while the guest runs. The setup reminder and toolbar warning disappear when the tools connect. Later hides the automatic reminder until the machine’s next session.")
                    Text("The tools accept shutdown and optional text clipboard requests only from this VM’s host. Clipboard sharing is off until you enable it in Machine Settings. The tools do not enable SSH, open network ports, or save passwords. Applications can still ask you to save changes before shutting down.")
                    Text("To remove the tools, open Terminal inside the guest and run:")
                    Text("sudo \"/Library/Application Support/MacVM/GuestTools/uninstall.sh\"")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Couldn’t Save Installer", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.orange.opacity(0.13), in: Circle())
                .foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveInstaller() {
        guard let source = installerURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save MacVM Guest Tools"
        panel.message = "Install this package inside your macOS virtual machine."
        panel.nameFieldStringValue = source.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try Data(contentsOf: source).write(to: destination, options: .atomic)
                savedURL = destination
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
