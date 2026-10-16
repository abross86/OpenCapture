import Foundation
import AppKit

private func fourCC(_ s: String) -> AEKeyword { s.utf8.reduce(0) { $0 << 8 | AEKeyword($1) } }

private func fileURL(_ v: Any?) -> URL? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
}

/// Enumerated parameters arrive as the integer-value (NSNumber) or, from some scripts, as the four-char code.
private func enumInt(_ v: Any?) -> Int? {
    if let n = v as? NSNumber {
        let i = n.intValue
        if i > 0x20202020 {   // a four-char enumerator code such as "Ve03": the last two characters are the value
            let code = String(bytes: [UInt8(i >> 24 & 0xff), UInt8(i >> 16 & 0xff), UInt8(i >> 8 & 0xff), UInt8(i & 0xff)], encoding: .ascii) ?? ""
            return Int(code.suffix(2))
        }
        return i
    }
    if let s = v as? String, let i = Int(s) { return i }
    return nil
}

@objc(StartCaptureScriptCommand) final class StartCaptureScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if !AppController.shared.startRecording(to: fileURL(evaluatedArguments?["path"])) { scriptErrorNumber = 1; scriptErrorString = "Could not start capture (already capturing, or no video input)." }
        return nil
    }
}
@objc(StartTLCaptureScriptCommand) final class StartTLCaptureScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if !AppController.shared.startTimelapse(to: fileURL(evaluatedArguments?["path"])) { scriptErrorNumber = 1; scriptErrorString = "Could not start timelapse capture." }
        return nil
    }
}
@objc(StartSMCaptureScriptCommand) final class StartSMCaptureScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if !AppController.shared.startStopMotion(to: fileURL(evaluatedArguments?["path"])) { scriptErrorNumber = 1; scriptErrorString = "Could not start stop-motion capture." }
        return nil
    }
}
@objc(TriggerSMCaptureScriptCommand) final class TriggerSMCaptureScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let sm = AppController.shared.stopMotion else { scriptErrorNumber = 2; scriptErrorString = "No stop-motion capture is in progress."; return nil }
        if !sm.captureFrame() { scriptErrorNumber = 3; scriptErrorString = "Stop-motion capture is busy." }
        return nil
    }
}
@objc(StopCaptureScriptCommand) final class StopCaptureScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let app = AppController.shared
        let path = app.currentOutputURL?.path ?? ""
        app.stopAnyCapture()
        return path
    }
}
@objc(SaveImageScriptCommand) final class SaveImageScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if ImageCapture.save(to: fileURL(evaluatedArguments?["path"])) == nil { scriptErrorNumber = 4; scriptErrorString = "Could not save image." }
        return nil
    }
}
@objc(GetVideoSourcesCommand) final class GetVideoSourcesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { DeviceManager.shared.videoDevices.map(\.localizedName) }
}
@objc(GetAudioSourcesCommand) final class GetAudioSourcesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { DeviceManager.shared.audioDevices.map(\.localizedName) }
}
@objc(GetStatusCommand) final class GetStatusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let e = CaptureEngine.shared, app = AppController.shared, p = Prefs.shared
        // Cocoa Scripting converts a dictionary keyed by the record's property names using the sdef.
        return [
            "isVideo": e.isVideoLive,
            "videoDeviceName": e.videoDevice?.localizedName ?? "",
            "videoFrameRate": e.measuredFPS > 0 ? e.measuredFPS : e.nominalFPS,
            "videoWidth": Int(e.videoSize.width),
            "videoHeight": Int(e.videoSize.height),
            "isAudio": e.isAudioLive,
            "audioDeviceName": e.audioDevice?.localizedName ?? "",
            "isRecording": app.mode != .idle,
            "currentRecordingDuration": app.currentDuration,
            "currentRecordingSize": Double(app.currentFileSize),
            "lastVideoError": e.lastVideoError,
            "lastAudioError": e.lastAudioError,
            "lastRecordingError": app.lastRecordingError,
            "videoEncoding": p.videoEncoding.rawValue,
            "audioEncoding": p.audioEncoding.rawValue,
        ] as [String: Any]
    }
}
@objc(SetPreferencesCommand) final class SetPreferencesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let args = evaluatedArguments else { return nil }
        let p = Prefs.shared, dm = DeviceManager.shared
        func num(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        func clamp(_ v: Double) -> Double { max(-50, min(50, v)) }
        if let name = args["videosource"] as? String {
            guard let d = dm.videoDevices.first(where: { $0.localizedName.caseInsensitiveCompare(name) == .orderedSame }) else {
                scriptErrorNumber = 5; scriptErrorString = "No video source named \"\(name)\"."; return nil
            }
            p.videoDeviceID = d.uniqueID; p.videoFormatKey = ""
        }
        if let name = args["audiosource"] as? String {
            if name.lowercased() == "none" { p.audioDeviceID = "none" }
            else if let d = dm.audioDevices.first(where: { $0.localizedName.caseInsensitiveCompare(name) == .orderedSame }) { p.audioDeviceID = d.uniqueID }
            else { scriptErrorNumber = 5; scriptErrorString = "No audio source named \"\(name)\"."; return nil }
        }
        if let s = args["capturedestination"] as? String { p.captureDestination = (s as NSString).expandingTildeInPath }
        if let b = args["fileconfirm"] as? Bool { p.askWhereToSave = b }
        if let s = args["filenameformat"] as? String { p.fileNameFormat = s }
        if let v = num("width") { p.videoWidth = Int(v); p.videoFormatKey = "" }
        if let v = num("height") { p.videoHeight = Int(v); p.videoFormatKey = "" }
        if let v = num("framerate") { p.videoFrameRate = v }
        if let s = args["overlay"] as? String { p.overlayText = s }
        if let v = num("fontsize") { p.overlayFontSize = Int(v) }
        if let v = num("brightness") { p.brightness = clamp(v) }
        if let v = num("contrast") { p.contrast = clamp(v) }
        if let v = num("sharpness") { p.sharpness = clamp(v) }
        if let v = num("saturation") { p.cbAdjust = clamp(v); p.crAdjust = clamp(v) }
        if let v = num("cb") { p.cbAdjust = clamp(v) }
        if let v = num("cr") { p.crAdjust = clamp(v) }
        if let i = enumInt(args["videoencoding"]), let e = VideoEncoding(rawValue: i) { p.videoEncoding = e }
        if let i = enumInt(args["audioencoding"]), let e = AudioEncoding(rawValue: i) { p.audioEncoding = e }
        if let i = enumInt(args["audioformat"]), let e = AudioFormat(rawValue: i) { p.audioFormat = e }
        if let v = num("audiodelay") { p.audioDelayMs = Int(v) }
        return nil
    }
}

// MARK: - OpenCapture Suite verbs

private func fileArg(_ cmd: NSScriptCommand, _ key: String) -> URL? { fileURL(cmd.evaluatedArguments?[key]) }

@objc(RecordMovieCommand) final class RecordMovieCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let app = AppController.shared
        guard app.mode == .idle else { scriptErrorNumber = 1; scriptErrorString = "A capture is already in progress."; return nil }
        let secs = (evaluatedArguments?["duration"] as? NSNumber)?.doubleValue
        guard app.startRecording(to: fileArg(self, "path"), limitSeconds: secs.map { Int($0.rounded(.up)) }) else {
            scriptErrorNumber = 1; scriptErrorString = "Could not start recording: \(AppController.shared.scriptLastError)"; return nil
        }
        return app.currentOutputURL?.path ?? ""
    }
}
@objc(CaptureImageCommand) final class CaptureImageCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let url = fileArg(self, "path")
        var format = (evaluatedArguments?["format"] as? NSNumber).flatMap { ImageFileFormat(rawValue: $0.intValue) }
        if format == nil, let ext = url?.pathExtension.lowercased() {
            switch ext { case "jpg", "jpeg": format = .jpeg; case "png": format = .png; case "tif", "tiff": format = .tiff; default: break }
        }
        guard let saved = ImageCapture.save(to: url, format: format) else {
            scriptErrorNumber = 4; scriptErrorString = "Could not save image: \(AppController.shared.scriptLastError)"; return nil
        }
        return saved.path
    }
}
@objc(CopyImageCommand) final class CopyImageCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard CaptureEngine.shared.latestFrame != nil else { scriptErrorNumber = 4; scriptErrorString = "No video frame available."; return nil }
        ImageCapture.copyToPasteboard(); return nil
    }
}
@objc(StartTimelapseCommand) final class StartTimelapseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let app = AppController.shared
        guard app.mode == .idle else { scriptErrorNumber = 1; scriptErrorString = "A capture is already in progress."; return nil }
        guard app.startTimelapse(to: fileArg(self, "path"), continuing: fileArg(self, "continuing")) else {
            scriptErrorNumber = 1; scriptErrorString = "Could not start timelapse: \(app.scriptLastError)"; return nil
        }
        return app.currentOutputURL?.path ?? ""
    }
}
@objc(StartStopMotionCommand) final class StartStopMotionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let app = AppController.shared
        guard app.mode == .idle else { scriptErrorNumber = 1; scriptErrorString = "A capture is already in progress."; return nil }
        guard app.startStopMotion(to: fileArg(self, "path"), continuing: fileArg(self, "continuing")) else {
            scriptErrorNumber = 1; scriptErrorString = "Could not start stop motion: \(app.scriptLastError)"; return nil
        }
        return app.currentOutputURL?.path ?? ""
    }
}
@objc(AddStopMotionFrameCommand) final class AddStopMotionFrameCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let sm = AppController.shared.stopMotion else { scriptErrorNumber = 2; scriptErrorString = "No stop-motion capture is in progress."; return nil }
        guard sm.captureFrame() else { scriptErrorNumber = 3; scriptErrorString = "Stop-motion capture is busy (averaging or writing)."; return nil }
        if sm.averagingCount > 1 {   // averaging completes asynchronously on the video queue; wait briefly so the count is accurate
            let deadline = Date().addingTimeInterval(5)
            while sm.isAveraging && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
        return sm.frameCount
    }
}
@objc(ExportStopMotionFramesCommand) final class ExportStopMotionFramesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let sm = AppController.shared.stopMotion else { scriptErrorNumber = 2; scriptErrorString = "No stop-motion capture is in progress."; return nil }
        guard let folder = fileArg(self, "folder") else { scriptErrorNumber = 7; scriptErrorString = "A destination folder is required."; return nil }
        var done = false, failure: Error?
        sm.exportStills(to: folder, format: Prefs.shared.imageCaptureFormat) { err in failure = err; done = true }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if let failure { scriptErrorNumber = 8; scriptErrorString = "Export failed: \(failure.localizedDescription)" }
        return nil
    }
}
@objc(ResetAdjustmentsCommand) final class ResetAdjustmentsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let p = Prefs.shared
        p.brightness = 0; p.contrast = 0; p.cbAdjust = 0; p.crAdjust = 0; p.sharpness = 0
        return nil
    }
}
@objc(RefreshDevicesCommand) final class RefreshDevicesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { DeviceManager.shared.refresh(); return nil }
}
