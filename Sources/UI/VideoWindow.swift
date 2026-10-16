import AppKit
import Combine
import UniformTypeIdentifiers

/// Main video window: live preview, recording HUD, drag-out image capture, keyboard shortcuts.
final class VideoWindowController: NSWindowController, NSWindowDelegate {
    let preview = VideoPreviewView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: nil)
    private let hud = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "No video input")
    private var accessory: NSTitlebarAccessoryViewController?
    private var cancellables = Set<AnyCancellable>()
    private var hudTimer: Timer?
    private var lastAppliedSize = CGSize.zero

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "OpenCapture"
        w.collectionBehavior = [.fullScreenPrimary]
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 160, height: 90)
        w.center()
        w.setFrameAutosaveName("VideoWindow")
        super.init(window: w)
        w.delegate = self

        let content = NSView(frame: w.contentView!.bounds)
        w.contentView = content
        preview.frame = content.bounds
        preview.autoresizingMask = [.width, .height]
        content.addSubview(preview)

        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 18, weight: .medium)
        placeholder.alignment = .center
        placeholder.sizeToFit()
        placeholder.frame = NSRect(x: (content.bounds.width - 300) / 2, y: (content.bounds.height - 24) / 2, width: 300, height: 24)
        placeholder.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        content.addSubview(placeholder)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: 30)
        hud.autoresizingMask = [.width, .maxYMargin]
        hud.isHidden = true
        hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hudLabel.textColor = .labelColor
        hudLabel.frame = NSRect(x: 12, y: 7, width: content.bounds.width - 24, height: 16)
        hudLabel.autoresizingMask = [.width]
        hudLabel.lineBreakMode = .byTruncatingTail
        hud.addSubview(hudLabel)
        content.addSubview(hud)

        CaptureEngine.shared.preview = preview
        bind()
        applyWindowPrefs()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func bind() {
        let engine = CaptureEngine.shared
        engine.$videoSize.receive(on: DispatchQueue.main).sink { [weak self] s in self?.applyVideoSize(s) }.store(in: &cancellables)
        Publishers.CombineLatest3(engine.$videoDevice, engine.$nominalFPS, engine.$measuredFPS)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dev, nominal, measured in
                guard let self, let w = self.window else { return }
                if let dev {
                    let s = engine.videoSize
                    let fps = measured > 0 ? measured : nominal
                    w.subtitle = "\(dev.localizedName)  \(Int(s.width))×\(Int(s.height))  \(String(format: "%.0f", fps)) fps"
                } else { w.subtitle = "No video device" }
                self.placeholder.isHidden = dev != nil
            }.store(in: &cancellables)
        AppController.shared.$mode.receive(on: DispatchQueue.main).sink { [weak self] mode in self?.modeChanged(mode) }.store(in: &cancellables)
        Prefs.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyWindowPrefs() }.store(in: &cancellables)
    }

    private func applyVideoSize(_ s: CGSize) {
        guard let w = window, s.width > 0, s.height > 0, s != lastAppliedSize else { return }
        lastAppliedSize = s
        w.contentAspectRatio = s
        guard !w.styleMask.contains(.fullScreen) else { return }
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var width = w.contentView?.bounds.width ?? 640
        var height = width * s.height / s.width
        let maxW = screen.width * 0.9, maxH = screen.height * 0.85
        if height > maxH { height = maxH; width = height * s.width / s.height }
        if width > maxW { width = maxW; height = width * s.height / s.width }
        let origin = w.frame.origin
        w.setContentSize(NSSize(width: width.rounded(), height: height.rounded()))
        var frame = w.frame
        frame.origin = NSPoint(x: origin.x, y: min(origin.y, screen.maxY - frame.height))
        w.setFrame(frame, display: true)
    }

    private func modeChanged(_ mode: AppController.Mode) {
        guard let w = window else { return }
        switch mode {
        case .idle: w.title = "OpenCapture"
        case .recording: w.title = "OpenCapture [CAPTURING]"
        case .timelapse: w.title = "OpenCapture [TIMELAPSE]"
        case .stopMotion: w.title = "OpenCapture [STOP-MOTION]"
        }
        hud.isHidden = mode == .idle
        hudTimer?.invalidate(); hudTimer = nil
        if mode != .idle {
            hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateHUD() }
            updateHUD()
        }
    }

    private func updateHUD() {
        let app = AppController.shared
        let engine = CaptureEngine.shared
        func clock(_ s: Double) -> String { String(format: "%02d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60) }
        func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch app.mode {
        case .recording:
            guard let r = app.recorder else { return }
            var t = "Duration: \(clock(r.duration))    Frame rate: \(String(format: "%.0f", engine.measuredFPS)) fps    File size: \(bytes(r.fileSize))"
            if r.droppedFrames > 0 { t += "    Dropped: \(r.droppedFrames)" }
            if let d = app.limitDeadline { t += "    Stops in: \(clock(max(0, d.timeIntervalSinceNow)))" }
            hudLabel.stringValue = t
        case .timelapse:
            guard let t = app.timelapse else { return }
            hudLabel.stringValue = "Frames: \(t.frameCount)    Movie length: \(clock(t.movieDuration))    Capturing \(t.framesPerCapture) every \(String(format: "%g", t.interval)) s    File size: \(bytes(t.recorder.fileSize))"
        case .stopMotion:
            guard let s = app.stopMotion else { return }
            var t = "Frames: \(s.frameCount)    Movie length: \(clock(s.movieDuration))    Press Return to add a frame"
            if s.isAveraging { t = "Averaging frames… \(Int(s.averagingProgress * 100))%" }
            if s.isWriting { t = "Writing movie…" }
            hudLabel.stringValue = t
        case .idle: break
        }
    }

    // MARK: Window preferences (float, title bar, accessory button)

    func applyWindowPrefs() {
        guard let w = window else { return }
        let p = Prefs.shared
        w.level = p.floatWindow ? .floating : .normal
        preview.flipHorizontal = p.liveFlipHorizontal
        let hide = !p.showTitleBar
        if hide != w.styleMask.contains(.fullSizeContentView) {
            if hide { w.styleMask.insert(.fullSizeContentView) } else { w.styleMask.remove(.fullSizeContentView) }
            w.titleVisibility = hide ? .hidden : .visible
            w.titlebarAppearsTransparent = hide
            w.isMovableByWindowBackground = hide
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = hide }
        }
        let wanted = p.titleBarButton
        if (accessory == nil) != (wanted == .none) || (accessory?.view as? NSButton)?.tag != wanted.rawValue {
            if let a = accessory { a.removeFromParent(); accessory = nil }
            if wanted != .none {
                let btn = NSButton(title: wanted == .saveImage ? "Save Image" : "Record", target: AppController.shared,
                                   action: wanted == .saveImage ? #selector(AppController.saveImage(_:)) : #selector(AppController.startStopRecording(_:)))
                btn.bezelStyle = .accessoryBarAction
                btn.controlSize = .small
                btn.tag = wanted.rawValue
                btn.image = NSImage(systemSymbolName: wanted == .saveImage ? "camera" : "record.circle", accessibilityDescription: nil)
                btn.imagePosition = .imageLeading
                btn.sizeToFit()
                let vc = NSTitlebarAccessoryViewController()
                vc.view = btn
                vc.layoutAttribute = .right
                w.addTitlebarAccessoryViewController(vc)
                accessory = vc
            }
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let w = window else { return }
        var f = w.frame; f.origin.x += dx; f.origin.y += dy
        w.setFrameOrigin(f.origin)
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { AppController.shared.stopMotion?.undoManager }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppController.shared.mode != .idle {
            let a = NSAlert(); a.messageText = "A capture is in progress."; a.informativeText = "Stop the capture before closing the video window."
            a.runModal(); return false
        }
        return true
    }
}

/// Preview view with first-responder keyboard handling, Copy, and drag-out of the current frame.
final class VideoPreviewView: MetalPreviewView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private var mouseDownPoint: NSPoint?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !AppController.shared.handleKey(event) { super.keyDown(with: event) }
    }
    @objc func copy(_ sender: Any?) { ImageCapture.copyToPasteboard() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil); mouseDownPoint = nil; return }
        mouseDownPoint = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 6 else { return }
        mouseDownPoint = nil
        let p = Prefs.shared
        guard let cg = ImageCapture.currentImage(size: p.imageCaptureSize) else { return }
        let type: UTType = [UTType.jpeg, .png, .tiff][p.imageCaptureFormat.rawValue]
        let provider = ImagePromiseProvider(fileType: type.identifier, delegate: self)
        provider.image = cg
        provider.copyFormat = p.imageCopyFormat
        let item = NSDraggingItem(pasteboardWriter: provider)
        let thumbW: CGFloat = 200, thumbH = thumbW * CGFloat(cg.height) / CGFloat(cg.width)
        let thumb = NSImage(cgImage: cg, size: NSSize(width: thumbW, height: thumbH))
        let loc = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: loc.x - thumbW / 2, y: loc.y - thumbH / 2, width: thumbW, height: thumbH), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let p = Prefs.shared
        var name = TokenFormatter.expand(p.fileNameFormat).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "Capture" }
        return name + "." + p.imageCaptureFormat.fileExtension
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let p = provider as? ImagePromiseProvider, let cg = p.image, let data = ImageCapture.encode(cg, format: Prefs.shared.imageCaptureFormat) else {
            completionHandler(NSError(domain: "OpenCapture", code: 4002, userInfo: [NSLocalizedDescriptionKey: "No image"])); return
        }
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

/// File promise (for Finder) that also offers in-memory image data (for apps that paste images).
final class ImagePromiseProvider: NSFilePromiseProvider {
    var image: CGImage?
    var copyFormat: ImageFileFormat = .tiff
    private var dataType: NSPasteboard.PasteboardType { ImageCapture.pasteboardType(for: copyFormat) }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [dataType]
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == dataType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == dataType { return image.flatMap { ImageCapture.encode($0, format: copyFormat) } }
        return super.pasteboardPropertyList(forType: type)
    }
}
