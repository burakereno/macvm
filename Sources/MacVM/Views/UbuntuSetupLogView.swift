import SwiftUI
import AppKit
import MacVMCore

struct UbuntuSetupLogView: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ubuntu Setup Log").font(.title2.bold())
            Text("Latest output from the VM. Retry in the machine’s Actions menu resumes completed steps.")
                .font(.caption).foregroundStyle(.secondary)
            ReadOnlySetupLog(text: text)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Refresh", action: refresh)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 780, height: 520).onAppear(perform: refresh)
    }
    private func refresh() {
        do { text = try UbuntuProvisioning.logText(directory: directory) }
        catch { text = error.localizedDescription }
    }
}

/// Native text layout handles large logs without a single oversized SwiftUI Text.
private struct ReadOnlySetupLog: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        editor.isEditable = false; editor.isSelectable = true
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        editor.scrollToEndOfDocument(nil)
    }
}
