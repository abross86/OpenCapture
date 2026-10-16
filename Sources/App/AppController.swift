import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Application delegate and the single owner of capture state (what is being recorded, where).
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation, ObservableObject {
    static let shared = AppController()

    enum Mode: Equatable { case idle, recording, timelapse, stopMotion }
    @Published private(set) var mode: Mode = .idle
    private(set) var recorder: MovieRecorder?
    private(set) var timelapse: TimelapseSession?
    @Published private(set) var stopMotion: StopMotionSession?
    private(set) var lastRecordingError = 0
    private(set) var limitDeadline: Date?
    private var limitTimer: Timer?
    private var timelapseFinalURL: URL?     // set when continuing an existing timelapse (written to a temp file)

    private(set) var videoWindow: VideoWindowController!
    private var prefsWindow: NSWindow?
    private var audioWindow: NSWindow?
    private var errorsWindow: NSWindow?
    private var stopMotionWindow: StopMotionWindowController?
    private var sheetWindow: NSWindow?
    private var terminating = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.build()
        videoWindow = VideoWindowController()
        videoWindow.showWindow(nil)
        videoWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ErrorLog.shared.log("App", "OpenCapture \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") started")
        requestPermissionsThenStart()
    }

    private func requestPermissionsThenStart() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { ErrorLog.shared.log("Video", "Camera access denied. Enable OpenCapture in System Settings › Privacy & Security › Camera.", code: -1) }
            AVCaptureDevice.requestAccess(for: .audio) { agranted in
                if !agranted { ErrorLog.shared.log("Audio", "Microphone access denied. Enable OpenCapture in System Settings › Privacy & Security › Microphone.", code: -1) }
                DispatchQueue.main.async { CaptureEngine.shared.applyPreferences(force: true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mode != .idle else { return .terminateNow }
        terminating = true
        stopAnyCapture()
        return .terminateLater
    }

    private func captureEnded() {
        mode = .idle
        if terminating { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        videoWindow.showWindow(nil); return true
    }

    // MARK: Output locations

    private func outputURL(ext: String) -> URL? {
        let p = Prefs.shared
        if p.askWhereToSave {
            let panel = NSSavePanel()
            if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
            panel.nameFieldStringValue = TokenFormatter.expand(p.fileNameFormat)
            panel.directoryURL = p.captureDestinationURL
            guard panel.runModal() == .OK, let u = panel.url else { return nil }
            return u
        }
        return TokenFormatter.uniqueFileURL(in: p.captureDestinationURL, format: p.fileNameFormat, ext: ext)
    }

    private func chooseExistingMovie(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        panel.message = prompt
        panel.directoryURL = Prefs.shared.captureDestinationURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info; a.alertStyle = .warning
        if let w = videoWindow.window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    private func requireVideo() -> Bool {
        let e = CaptureEngine.shared
        guard e.videoDevice != nil, e.videoSize.width > 0 else { alert("No video input", "Connect a capture device or choose a video source in Preferences."); return false }
        return true
    }

    var currentDuration: Double {
        switch mode {
        case .recording: return recorder?.duration ?? 0
        case .timelapse: return timelapse?.movieDuration ?? 0
        case .stopMotion: return stopMotion?.movieDuration ?? 0
        case .idle: return 0
        }
    }
    /// The file the current capture will produce (the final path, even while a temp file is in use).
    var currentOutputURL: URL? {
        switch mode {
        case .recording: return recorder?.url
        case .timelapse: return timelapseFinalURL ?? timelapse?.recorder.url
        case .stopMotion: return stopMotion?.url
        case .idle: return nil
        }
    }
    var currentFileSize: Int64 {
        switch mode {
        case .recording: return recorder?.fileSize ?? 0
        case .timelapse: return timelapse?.recorder.fileSize ?? 0
        default: return 0
        }
    }

    // MARK: Movie recording

    @discardableResult
    func startRecording(to url: URL? = nil, limitSeconds: Int? = nil) -> Bool {
        guard mode == .idle, requireVideo() else { return false }
        let e = CaptureEngine.shared, p = Prefs.shared
        let fps = e.measuredFPS > 0 ? e.measuredFPS : (e.nominalFPS > 0 ? e.nominalFPS : 30)
        let cfg = RecordingConfig(prefs: p, hasAudio: e.audioDevice != nil, fps: fps)
        guard let target = url ?? outputURL(ext: cfg.fileExtension) else { return false }
        do {
            let rec = try MovieRecorder(url: target, size: e.videoSize, config: cfg, realTime: true)
            recorder = rec
            e.addSink(rec)
            mode = .recording
            ErrorLog.shared.log("Recording", "Started: \(target.path) [\(cfg.videoEncoding.label), \(cfg.hasAudio ? cfg.audioEncoding.label : "no audio")]")
            if let limit = limitSeconds, limit > 0 {
                limitDeadline = Date().addingTimeInterval(TimeInterval(limit))
                limitTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(limit), repeats: false) { [weak self] _ in self?.stopRecording() }
            }
            return true
        } catch {
            lastRecordingError = (error as NSError).code
            ErrorLog.shared.log("Recording", "Could not start: \(error.localizedDescription)", code: lastRecordingError)
            alert("Could not start recording", error.localizedDescription)
            return false
        }
    }

    func stopRecording() {
        guard let rec = recorder else { return }
        limitTimer?.invalidate(); limitTimer = nil; limitDeadline = nil
        CaptureEngine.shared.removeSink(rec)
        recorder = nil
        rec.finish { [weak self] err in
            DispatchQueue.main.async {
                if let err {
                    self?.lastRecordingError = (err as NSError).code
                    ErrorLog.shared.log("Recording", "Failed: \(err.localizedDescription)", code: (err as NSError).code)
                    self?.alert("Recording failed", err.localizedDescription)
                } else {
                    ErrorLog.shared.log("Recording", "Saved \(rec.url.lastPathComponent): \(rec.frameCount) frames, \(String(format: "%.1f", rec.duration)) s, \(rec.droppedFrames) dropped")
                }
                self?.captureEnded()
            }
        }
    }

    // MARK: Timelapse

    @discardableResult
    func startTimelapse(to url: URL? = nil, continuing existing: URL? = nil) -> Bool {
        guard mode == .idle, requireVideo() else { return false }
        let e = CaptureEngine.shared, p = Prefs.shared
        let cfgExt = RecordingConfig(prefs: p, hasAudio: false, fps: p.timelapsePlaybackFPS).fileExtension
        let target: URL
        if let existing {
            target = existing.deletingLastPathComponent().appendingPathComponent(".\(existing.lastPathComponent).continue.\(cfgExt)")
            timelapseFinalURL = existing
        } else {
            guard let u = url ?? outputURL(ext: cfgExt) else { return false }
            target = u; timelapseFinalURL = nil
        }
        do {
            let session = try TimelapseSession(url: target, size: e.videoSize, prefs: p)
            timelapse = session
            mode = .timelapse
            let begin = {
                e.addSink(session)
                session.start()
                ErrorLog.shared.log("Timelapse", "Started: \(target.path) — \(session.framesPerCapture) frame(s) every \(String(format: "%g", session.interval)) s, playback \(String(format: "%g", session.playbackFPS)) fps")
            }
            if let existing {
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try session.preload(from: existing); DispatchQueue.main.async(execute: begin) }
                    catch { DispatchQueue.main.async { self.timelapse = nil; self.mode = .idle; self.alert("Could not continue timelapse", error.localizedDescription) } }
                }
            } else { begin() }
            return true
        } catch {
            ErrorLog.shared.log("Timelapse", "Could not start: \(error.localizedDescription)", code: (error as NSError).code)
            alert("Could not start timelapse", error.localizedDescription)
            return false
        }
    }

    func stopTimelapse() {
        guard let t = timelapse else { return }
        CaptureEngine.shared.removeSink(t)
        timelapse = nil
        let final = timelapseFinalURL; timelapseFinalURL = nil
        t.stop { [weak self] err in
            DispatchQueue.main.async {
                if let err { ErrorLog.shared.log("Timelapse", "Failed: \(err.localizedDescription)", code: (err as NSError).code); self?.alert("Timelapse failed", err.localizedDescription) }
                else if let final {
                    do { try? FileManager.default.removeItem(at: final); try FileManager.default.moveItem(at: t.recorder.url, to: final) }
                    catch { ErrorLog.shared.log("Timelapse", "Could not replace \(final.lastPathComponent): \(error.localizedDescription)") }
                    ErrorLog.shared.log("Timelapse", "Saved \(final.lastPathComponent): \(t.frameCount) frames")
                } else { ErrorLog.shared.log("Timelapse", "Saved \(t.recorder.url.lastPathComponent): \(t.frameCount) frames") }
                self?.captureEnded()
            }
        }
    }

    // MARK: Stop-motion

    @discardableResult
    func startStopMotion(to url: URL? = nil, continuing existing: URL? = nil) -> Bool {
        guard mode == .idle, requireVideo() else { return false }
        let e = CaptureEngine.shared, p = Prefs.shared
        guard let target = existing ?? url ?? outputURL(ext: "mov") else { return false }
        let session = StopMotionSession(url: target, size: e.videoSize, prefs: p)
        let begin = { [self] in
            stopMotion = session
            e.addSink(session)
            mode = .stopMotion
            let wc = StopMotionWindowController(session: session)
            stopMotionWindow = wc
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            ErrorLog.shared.log("Stop-motion", "Started: \(target.path) — averaging \(session.averagingCount) frame(s), playback \(String(format: "%g", session.playbackFPS)) fps")
        }
        if let existing {
            DispatchQueue.global(qos: .userInitiated).async {
                do { try session.load(from: existing); DispatchQueue.main.async(execute: begin) }
                catch { DispatchQueue.main.async { self.alert("Could not continue stop-motion movie", error.localizedDescription) } }
            }
        } else { begin() }
        return true
    }

    func stopStopMotion() {
        guard let s = stopMotion, !s.isWriting else { return }
        CaptureEngine.shared.removeSink(s)
        if s.frameCount == 0 {
            stopMotion = nil; stopMotionWindow?.close(); stopMotionWindow = nil
            captureEnded(); return
        }
        s.finish(prefs: Prefs.shared) { [weak self] err in
            if let err { ErrorLog.shared.log("Stop-motion", "Failed: \(err.localizedDescription)", code: (err as NSError).code); self?.alert("Stop-motion movie failed", err.localizedDescription) }
            else { ErrorLog.shared.log("Stop-motion", "Saved \(s.url.lastPathComponent): \(s.frameCount) frames") }
            self?.stopMotion = nil
            self?.stopMotionWindow?.close(); self?.stopMotionWindow = nil
            self?.captureEnded()
        }
    }

    func stopAnyCapture() {
        switch mode {
        case .recording: stopRecording()
        case .timelapse: stopTimelapse()
        case .stopMotion: stopStopMotion()
        case .idle: break
        }
    }

    // MARK: Keyboard (video + stop-motion windows)

    func handleKey(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty
        if let sm = stopMotion, plain {
            switch chars {
            case "\r", "\u{3}": sm.captureFrame(); return true
            case "o", "O": sm.onionSkin.toggle(); return true
            case " ": sm.togglePlayback(); return true
            case "\u{7f}", "\u{F728}": sm.deleteSelectedFrame(); return true
            case "\u{F702}": sm.stopPlayback(); sm.selectedIndex = max(0, sm.selectedIndex - 1); return true
            case "\u{F703}": sm.stopPlayback(); sm.selectedIndex = min(sm.frameCount - 1, sm.selectedIndex + 1); return true
            default: break
            }
        }
        if plain, chars == " " || chars == "\r" { return false }
        return false
    }

    // MARK: Menu actions

    @objc func saveImage(_ sender: Any?) { ImageCapture.save() }
    @objc func copy(_ sender: Any?) { ImageCapture.copyToPasteboard() }

    @objc func startStopRecording(_ sender: Any?) {
        if mode == .recording { stopRecording() } else { startRecording() }
    }

    @objc func startTimeLimitedRecording(_ sender: Any?) {
        guard mode == .idle, let host = videoWindow.window else { return }
        let sheet = PanelWindows.make(title: "", autosave: "", TimeLimitSheet(initialSeconds: Prefs.shared.recordingLimitSeconds, onStart: { [weak self] secs in
            guard let self, let s = self.sheetWindow else { return }
            host.endSheet(s); self.sheetWindow = nil
            Prefs.shared.recordingLimitSeconds = secs
            self.startRecording(limitSeconds: secs)
        }, onCancel: { [weak self] in
            if let s = self?.sheetWindow { host.endSheet(s) }; self?.sheetWindow = nil
        }), resizable: false)
        sheetWindow = sheet
        host.beginSheet(sheet)
    }

    @objc func startStopTimelapse(_ sender: Any?) {
        if mode == .timelapse { stopTimelapse() } else { startTimelapse() }
    }
    @objc func continueTimelapse(_ sender: Any?) {
        guard mode == .idle, let u = chooseExistingMovie(prompt: "Choose the timelapse movie to continue") else { return }
        startTimelapse(continuing: u)
    }
    @objc func startStopStopMotion(_ sender: Any?) {
        if mode == .stopMotion { stopStopMotion() } else { startStopMotion() }
    }
    @objc func continueStopMotion(_ sender: Any?) {
        guard mode == .idle, let u = chooseExistingMovie(prompt: "Choose the stop-motion movie to continue") else { return }
        startStopMotion(continuing: u)
    }
    @objc func exportStopMotionImages(_ sender: Any?) {
        guard let s = stopMotion else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose a folder for the still image files"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        s.exportStills(to: folder, format: Prefs.shared.imageCaptureFormat) { [weak self] err in
            if let err { self?.alert("Export failed", err.localizedDescription) }
            else { ErrorLog.shared.log("Stop-motion", "Exported \(s.frameCount) images to \(folder.path)") }
        }
    }
    @objc func addStopMotionFrame(_ sender: Any?) { stopMotion?.captureFrame() }
    @objc func toggleOnionSkin(_ sender: Any?) { stopMotion?.onionSkin.toggle() }
    @objc func toggleStopMotionPlayback(_ sender: Any?) { stopMotion?.togglePlayback() }

    @objc func floatVideoWindow(_ sender: Any?) { Prefs.shared.floatWindow.toggle() }
    @objc func toggleTitleBar(_ sender: Any?) { Prefs.shared.showTitleBar.toggle() }
    @objc func toggleLiveFlip(_ sender: Any?) { Prefs.shared.liveFlipHorizontal.toggle() }
    @objc func toggleFullScreen(_ sender: Any?) { videoWindow.window?.toggleFullScreen(nil) }
    @objc func windowUp(_ sender: Any?) { videoWindow.nudge(dx: 0, dy: 10) }
    @objc func windowDown(_ sender: Any?) { videoWindow.nudge(dx: 0, dy: -10) }
    @objc func windowLeft(_ sender: Any?) { videoWindow.nudge(dx: -10, dy: 0) }
    @objc func windowRight(_ sender: Any?) { videoWindow.nudge(dx: 10, dy: 0) }
    @objc func toggleAudioMonitor(_ sender: Any?) { Prefs.shared.audioMonitorOn.toggle() }

    @objc func openVideoWindow(_ sender: Any?) { videoWindow.showWindow(nil); videoWindow.window?.makeKeyAndOrderFront(nil) }
    @objc func openStopMotionWindow(_ sender: Any?) { stopMotionWindow?.showWindow(nil) }
    @objc func openPreferences(_ sender: Any?) {
        if prefsWindow == nil { prefsWindow = PanelWindows.make(title: "OpenCapture Preferences", autosave: "PrefsWindow", PreferencesView()) }
        prefsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openAudioWindow(_ sender: Any?) {
        if audioWindow == nil { audioWindow = PanelWindows.make(title: "OpenCapture Audio", autosave: "AudioWindow", AudioView(), resizable: false) }
        audioWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openErrorsWindow(_ sender: Any?) {
        if errorsWindow == nil { errorsWindow = PanelWindows.make(title: "OpenCapture Log", autosave: "ErrorsWindow", ErrorsView()) }
        errorsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openUserManual(_ sender: Any?) {
        if let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "manual") { NSWorkspace.shared.open(u) }
        else { NSWorkspace.shared.open(URL(string: "https://github.com/alexbross/OpenCapture")!) }
    }
    @objc func openProjectPage(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/alexbross/OpenCapture")!) }
    @objc func revealCaptureFolder(_ sender: Any?) { NSWorkspace.shared.open(Prefs.shared.captureDestinationURL) }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(startStopRecording(_:)):
            item.title = mode == .recording ? "Stop Recording" : "Start Recording…"
            return mode == .idle || mode == .recording
        case #selector(startTimeLimitedRecording(_:)): return mode == .idle
        case #selector(startStopTimelapse(_:)):
            item.title = mode == .timelapse ? "Stop Timelapse Recording" : "Start Timelapse Recording…"
            return mode == .idle || mode == .timelapse
        case #selector(continueTimelapse(_:)), #selector(continueStopMotion(_:)): return mode == .idle
        case #selector(startStopStopMotion(_:)):
            item.title = mode == .stopMotion ? "Stop Stop-Motion Recording" : "Start Stop-Motion Recording…"
            return (mode == .idle || mode == .stopMotion) && !(stopMotion?.isWriting ?? false)
        case #selector(exportStopMotionImages(_:)), #selector(addStopMotionFrame(_:)), #selector(toggleStopMotionPlayback(_:)), #selector(openStopMotionWindow(_:)):
            return stopMotion != nil
        case #selector(toggleOnionSkin(_:)):
            item.state = (stopMotion?.onionSkin ?? false) ? .on : .off
            return stopMotion != nil
        case #selector(floatVideoWindow(_:)): item.state = Prefs.shared.floatWindow ? .on : .off; return true
        case #selector(toggleTitleBar(_:)): item.state = Prefs.shared.showTitleBar ? .on : .off; return true
        case #selector(toggleLiveFlip(_:)): item.state = Prefs.shared.liveFlipHorizontal ? .on : .off; return true
        case #selector(toggleAudioMonitor(_:)): item.state = Prefs.shared.audioMonitorOn ? .on : .off; return true
        case #selector(saveImage(_:)), #selector(copy(_:)): return CaptureEngine.shared.latestFrame != nil
        default: return true
        }
    }
}
