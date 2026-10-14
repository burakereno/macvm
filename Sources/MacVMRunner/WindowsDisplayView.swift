import AppKit
import WindowsPrototypeCore

final class WindowsDisplayView: NSView {
    let client = LocalDisplayClient()
    var image: CGImage? { didSet {
        needsDisplay = true
        if let image, oldValue?.width != image.width || oldValue?.height != image.height {
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel("Windows display")
            setAccessibilityValue("\(image.width) × \(image.height) pixels")
        }
    } }
    private var tracking: NSTrackingArea?
    private var resizeWork: DispatchWorkItem?
    var defersResolutionChanges = false { didSet { if !defersResolutionChanges { scheduleResize() } } }
    private var heldKeys: [UInt16: UInt32] = [:]
    private var heldModifiers = Set<UInt32>()
    private var buttons: UInt8 = 0
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var viewport: NSRect {
        guard let image else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleResize() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleResize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleResize() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); scheduleResize() }
    private func scheduleResize() {
        resizeWork?.cancel()
        guard window != nil, !defersResolutionChanges else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.defersResolutionChanges else { return }
            let pixels = self.convertToBacking(self.bounds).size
            guard let size = DisplaySize(width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded())) else { return }
            self.client.resizeDisplay(to: size)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let rect = viewport
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let pixels = convertToBacking(rect).size
        context.interpolationQuality = Int(pixels.width.rounded()) == image.width && Int(pixels.height.rounded()) == image.height ? .none : .high
        context.draw(image, in: NSRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func rightMouseDown(with event: NSEvent) { buttons |= 4; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; pointer(event) }
    override func otherMouseDown(with event: NSEvent) { buttons |= 2; pointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let wheel: UInt8 = delta > 0 ? 8 : 16
        for _ in 0..<min(6, max(1, Int(abs(delta) / (event.hasPreciseScrollingDeltas ? 10 : 1)))) {
            pointer(event, extra: wheel); pointer(event)
        }
    }
    private func pointer(_ event: NSEvent, extra: UInt8 = 0) {
        guard let image else { return }
        let p = convert(event.locationInWindow, from: nil), rect = viewport
        guard rect.width > 0, rect.height > 0 else { return }
        let x = Int((p.x - rect.minX) / rect.width * CGFloat(image.width))
        let y = Int((p.y - rect.minY) / rect.height * CGFloat(image.height))
        client.pointer(x: max(0, min(image.width - 1, x)), y: max(0, min(image.height - 1, y)), buttons: buttons | extra)
    }
    override func keyDown(with event: NSEvent) {
        guard let symbol = WindowsKeyboard.keysym(keyCode: event.keyCode) else { return }
        synchronizeModifiers(event.modifierFlags)
        heldKeys[event.keyCode] = symbol; client.key(symbol, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if let symbol = heldKeys.removeValue(forKey: event.keyCode) { client.key(symbol, down: false) }
        synchronizeModifiers(event.modifierFlags)
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == 57 { client.key(0xffe5, down: true); client.key(0xffe5, down: false); return }
        synchronizeModifiers(event.modifierFlags)
    }
    private func synchronizeModifiers(_ flags: NSEvent.ModifierFlags) {
        // Key events can carry modifier state without a preceding flagsChanged
        // event, including after focus changes. Use the current state rather
        // than toggling remembered state on every modifier notification.
        let desired = WindowsKeyboard.modifiers(rawFlags: flags.rawValue)
        for symbol in heldModifiers.subtracting(desired) { client.key(symbol, down: false) }
        for symbol in desired.subtracting(heldModifiers) { client.key(symbol, down: true) }
        heldModifiers = desired
    }
    func releaseInput() {
        for symbol in heldKeys.values { client.key(symbol, down: false) }
        for symbol in heldModifiers { client.key(symbol, down: false) }
        heldKeys.removeAll(); heldModifiers.removeAll(); buttons = 0
        client.pointer(x: 0, y: 0, buttons: 0)
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
}
