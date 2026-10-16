import AppKit
import Combine
import CoreImage

/// Stop-motion window: shows the selected movie frame, with optional onion-skin of the live video,
/// a scrubber, playback and the frame counter.
final class StopMotionWindowController: NSWindowController, NSWindowDelegate {
    let session: StopMotionSession
    private let preview: MetalPreviewView
    private let playButton = NSButton()
    private let scrubber = NSSlider()
    private let counter = NSTextField(labelWithString: "0/0")
    private let onionButton = NSButton()
    private let addButton = NSButton()
    private let progress = NSProgressIndicator()
    private var cancellables = Set<AnyCancellable>()

    init(session: StopMotionSession) {
        self.session = session
        preview = StopMotionPreviewView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: nil)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Stop-Motion"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 320, height: 220)
        w.setFrameAutosaveName("StopMotionWindow")
        super.init(window: w)
        w.delegate = self
        buildUI()
        bind()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let w = window else { return }
        let content = NSView(frame: w.contentView!.bounds)
        w.contentView = content
        let barH: CGFloat = 40
        preview.frame = NSRect(x: 0, y: barH, width: content.bounds.width, height: content.bounds.height - barH)
        preview.autoresizingMask = [.width, .height]
        content.addSubview(preview)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: barH))
        bar.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(bar)

        playButton.bezelStyle = .texturedRounded
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self; playButton.action = #selector(togglePlay)
        playButton.frame = NSRect(x: 8, y: 7, width: 36, height: 26)
        playButton.toolTip = "Start or stop playback (Space)"
        bar.addSubview(playButton)

        scrubber.minValue = 0; scrubber.maxValue = 0
        scrubber.target = self; scrubber.action = #selector(scrub)
        scrubber.isContinuous = true
        scrubber.frame = NSRect(x: 52, y: 9, width: content.bounds.width - 52 - 250, height: 22)
        scrubber.autoresizingMask = [.width]
        scrubber.toolTip = "Click to jump to any position in the movie"
        bar.addSubview(scrubber)

        counter.alignment = .center
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counter.frame = NSRect(x: content.bounds.width - 246, y: 11, width: 70, height: 18)
        counter.autoresizingMask = [.minXMargin]
        counter.toolTip = "Selected frame / total number of frames"
        bar.addSubview(counter)

        onionButton.setButtonType(.pushOnPushOff)
        onionButton.bezelStyle = .texturedRounded
        onionButton.title = "Onion skin"
        onionButton.target = self; onionButton.action = #selector(toggleOnion)
        onionButton.frame = NSRect(x: content.bounds.width - 172, y: 7, width: 90, height: 26)
        onionButton.autoresizingMask = [.minXMargin]
        onionButton.toolTip = "Overlay the live video on the selected frame (O)"
        bar.addSubview(onionButton)

        addButton.bezelStyle = .texturedRounded
        addButton.title = "Add Frame"
        addButton.target = self; addButton.action = #selector(addFrame)
        addButton.frame = NSRect(x: content.bounds.width - 78, y: 7, width: 72, height: 26)
        addButton.autoresizingMask = [.minXMargin]
        addButton.toolTip = "Capture the live video as the next frame (Return)"
        bar.addSubview(addButton)

        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isIndeterminate = false
        progress.frame = NSRect(x: 52, y: 2, width: scrubber.frame.width, height: 6)
        progress.autoresizingMask = [.width]
        progress.isHidden = true
        bar.addSubview(progress)

        preview.overlayProvider = { [weak self] in
            guard let self, self.session.onionSkin, !self.session.isPlaying else { return nil }
            return CaptureEngine.shared.snapshotImage()
        }
        preview.overlayAlpha = 0.5
    }

    private func bind() {
        session.$frames.combineLatest(session.$selectedIndex).receive(on: DispatchQueue.main).sink { [weak self] frames, idx in
            guard let self else { return }
            self.scrubber.maxValue = Double(max(0, frames.count - 1))
            self.scrubber.isEnabled = frames.count > 1
            self.scrubber.doubleValue = Double(max(0, idx))
            self.counter.stringValue = "\(frames.isEmpty ? 0 : idx + 1)/\(frames.count)"
            if let cg = self.session.image(at: idx) { self.preview.display(image: CIImage(cgImage: cg)) }
            else { self.preview.display(image: nil) }
        }.store(in: &cancellables)
        session.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
            self?.playButton.image = NSImage(systemSymbolName: playing ? "stop.fill" : "play.fill", accessibilityDescription: nil)
        }.store(in: &cancellables)
        session.$onionSkin.receive(on: DispatchQueue.main).sink { [weak self] on in
            self?.onionButton.state = on ? .on : .off
            self?.preview.markDirty()
        }.store(in: &cancellables)
        session.$isAveraging.combineLatest(session.$averagingProgress, session.$isWriting).receive(on: DispatchQueue.main).sink { [weak self] avg, prog, writing in
            self?.progress.isHidden = !(avg || writing)
            self?.progress.isIndeterminate = writing
            if writing { self?.progress.startAnimation(nil) } else { self?.progress.stopAnimation(nil); self?.progress.doubleValue = prog }
            self?.addButton.isEnabled = !(avg || writing)
        }.store(in: &cancellables)
        CaptureEngine.shared.$videoSize.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard s.width > 0, s.height > 0 else { return }
            self?.window?.contentAspectRatio = CGSize(width: s.width, height: s.height + 40 * s.width / (self?.window?.contentView?.bounds.width ?? 640))
        }.store(in: &cancellables)
    }

    @objc private func togglePlay() { session.togglePlayback() }
    @objc private func scrub() { session.stopPlayback(); session.selectedIndex = Int(scrubber.doubleValue.rounded()) }
    @objc private func toggleOnion() { session.onionSkin.toggle() }
    @objc private func addFrame() { session.captureFrame() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AppController.shared.stopStopMotion()
        return false   // closed by the controller when the movie has been written
    }
}

final class StopMotionPreviewView: MetalPreviewView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if !AppController.shared.handleKey(event) { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
}
