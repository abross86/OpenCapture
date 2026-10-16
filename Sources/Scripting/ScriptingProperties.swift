import AppKit
import AVFoundation

// Scriptable properties of the `application` object. Cocoa Scripting asks the app delegate
// (AppController) via application(_:delegateHandlesKey:) and then uses KVC on these @objc members.
// Setting a value changes the preference, which the engine picks up like any Preferences change.

private let scriptKeys: Set<String> = [
    "scriptVersion",
    "scriptVideoLive", "scriptAudioLive", "scriptVideoDeviceName", "scriptAudioDeviceName",
    "scriptVideoWidth", "scriptVideoHeight", "scriptFrameRate", "scriptVideoSources", "scriptAudioSources", "scriptVideoFormats",
    "scriptCaptureMode", "scriptRecording", "scriptRecordingDuration", "scriptRecordingFileSize", "scriptRecordingFile",
    "scriptStopMotionFrameCount", "scriptLastError",
    "scriptVideoSource", "scriptVideoFormat", "scriptRequestedWidth", "scriptRequestedHeight", "scriptRequestedFrameRate",
    "scriptTransformation", "scriptMirrorLiveVideo",
    "scriptAudioSource", "scriptAudioFormat", "scriptAudioLeftChannel", "scriptAudioRightChannel", "scriptAudioDelay",
    "scriptAudioMonitoring", "scriptAudioMonitorVolume",
    "scriptBrightness", "scriptContrast", "scriptCb", "scriptCr", "scriptSaturation", "scriptSharpness", "scriptTextOverlay", "scriptOverlayFontSize",
    "scriptCaptureDestination", "scriptFileNameFormat", "scriptAskWhereToSave", "scriptImageCaptureFormat", "scriptImageCopyFormat",
    "scriptImageCaptureSize", "scriptClickSound",
    "scriptTimelapseFrames", "scriptTimelapseInterval", "scriptTimelapsePlaybackRate", "scriptStopMotionAveraging", "scriptStopMotionPlaybackRate",
    "scriptOnionSkin", "scriptVideoEncoding", "scriptAudioEncoding", "scriptFloatWindow", "scriptShowTitleBar",
]

extension AppController {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool { scriptKeys.contains(key) }

    private var prefs: Prefs { Prefs.shared }
    private var engine: CaptureEngine { CaptureEngine.shared }
    private func clamp50(_ v: Double) -> Double { max(-50, min(50, v)) }

    /// Raises an AppleScript error for the command currently executing (if any).
    private func scriptError(_ number: Int, _ message: String) {
        if let cmd = NSScriptCommand.current() { cmd.scriptErrorNumber = number; cmd.scriptErrorString = message }
        else { ErrorLog.shared.log("Script", message, code: number) }
    }

    // MARK: Read-only state

    @objc var scriptVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    @objc var scriptVideoLive: Bool { engine.isVideoLive }
    @objc var scriptAudioLive: Bool { engine.isAudioLive }
    @objc var scriptVideoDeviceName: String { engine.videoDevice?.localizedName ?? "" }
    @objc var scriptAudioDeviceName: String { engine.audioDevice?.localizedName ?? "" }
    @objc var scriptVideoWidth: Int { Int(engine.videoSize.width) }
    @objc var scriptVideoHeight: Int { Int(engine.videoSize.height) }
    @objc var scriptFrameRate: Double { engine.measuredFPS > 0 ? engine.measuredFPS : engine.nominalFPS }
    @objc var scriptVideoSources: [String] { DeviceManager.shared.videoDevices.map(\.localizedName) }
    @objc var scriptAudioSources: [String] { DeviceManager.shared.audioDevices.map(\.localizedName) }
    @objc var scriptVideoFormats: [String] {
        guard let d = DeviceManager.shared.videoDevice(preferredID: prefs.videoDeviceID) else { return [] }
        return d.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video }.map(DeviceManager.formatLabel)
    }
    @objc var scriptCaptureMode: Int {
        switch mode { case .idle: return 0; case .recording: return 1; case .timelapse: return 2; case .stopMotion: return 3 }
    }
    @objc var scriptRecording: Bool { mode != .idle }
    @objc var scriptRecordingDuration: Double { currentDuration }
    @objc var scriptRecordingFileSize: Int { Int(currentFileSize) }
    @objc var scriptRecordingFile: String { currentOutputURL?.path ?? "" }
    @objc var scriptStopMotionFrameCount: Int { stopMotion?.frameCount ?? 0 }
    @objc var scriptLastError: String { ErrorLog.shared.entries.last(where: { $0.code != 0 })?.message ?? "" }

    // MARK: Video input

    @objc var scriptVideoSource: String {
        get { prefs.videoDeviceID.isEmpty ? "automatic" : (DeviceManager.shared.videoDevices.first { $0.uniqueID == prefs.videoDeviceID }?.localizedName ?? prefs.videoDeviceID) }
        set {
            if newValue.isEmpty || newValue.caseInsensitiveCompare("automatic") == .orderedSame { prefs.videoDeviceID = ""; prefs.videoFormatKey = ""; return }
            guard let d = DeviceManager.shared.videoDevices.first(where: { $0.localizedName.caseInsensitiveCompare(newValue) == .orderedSame }) else {
                scriptError(5, "No video source named \"\(newValue)\". Available: \(scriptVideoSources.joined(separator: ", "))"); return
            }
            if d.uniqueID != prefs.videoDeviceID { prefs.videoFormatKey = "" }
            prefs.videoDeviceID = d.uniqueID
        }
    }
    @objc var scriptVideoFormat: String {
        get {
            guard !prefs.videoFormatKey.isEmpty, let d = DeviceManager.shared.videoDevice(preferredID: prefs.videoDeviceID),
                  let f = d.formats.first(where: { DeviceManager.formatKey($0) == prefs.videoFormatKey }) else { return "automatic" }
            return DeviceManager.formatLabel(f)
        }
        set {
            if newValue.isEmpty || newValue.caseInsensitiveCompare("automatic") == .orderedSame { prefs.videoFormatKey = ""; return }
            guard let d = DeviceManager.shared.videoDevice(preferredID: prefs.videoDeviceID) else { scriptError(6, "No video device."); return }
            let norm = { (s: String) in s.replacingOccurrences(of: " ", with: "").lowercased() }
            guard let f = d.formats.first(where: { norm(DeviceManager.formatLabel($0)) == norm(newValue) || DeviceManager.formatKey($0) == newValue }) else {
                scriptError(6, "No video format \"\(newValue)\". Available: \(scriptVideoFormats.joined(separator: " | "))"); return
            }
            prefs.videoFormatKey = DeviceManager.formatKey(f)
        }
    }
    @objc var scriptRequestedWidth: Int { get { prefs.videoWidth } set { prefs.videoWidth = max(0, newValue); prefs.videoFormatKey = "" } }
    @objc var scriptRequestedHeight: Int { get { prefs.videoHeight } set { prefs.videoHeight = max(0, newValue); prefs.videoFormatKey = "" } }
    @objc var scriptRequestedFrameRate: Double { get { prefs.videoFrameRate } set { prefs.videoFrameRate = max(0, newValue) } }
    @objc var scriptTransformation: Int { get { prefs.videoTransform.rawValue } set { if let t = VideoTransform(rawValue: newValue) { prefs.videoTransform = t } } }
    @objc var scriptMirrorLiveVideo: Bool { get { prefs.liveFlipHorizontal } set { prefs.liveFlipHorizontal = newValue } }

    // MARK: Audio input

    @objc var scriptAudioSource: String {
        get {
            if prefs.audioDeviceID == "none" { return "none" }
            if prefs.audioDeviceID.isEmpty { return "automatic" }
            return DeviceManager.shared.audioDevices.first { $0.uniqueID == prefs.audioDeviceID }?.localizedName ?? prefs.audioDeviceID
        }
        set {
            let v = newValue.lowercased()
            if v == "none" { prefs.audioDeviceID = "none"; return }
            if v.isEmpty || v == "automatic" { prefs.audioDeviceID = ""; return }
            guard let d = DeviceManager.shared.audioDevices.first(where: { $0.localizedName.caseInsensitiveCompare(newValue) == .orderedSame }) else {
                scriptError(5, "No audio source named \"\(newValue)\". Available: \(scriptAudioSources.joined(separator: ", "))"); return
            }
            prefs.audioDeviceID = d.uniqueID
        }
    }
    @objc var scriptAudioFormat: Int { get { prefs.audioFormat.rawValue } set { if let f = AudioFormat(rawValue: newValue) { prefs.audioFormat = f } } }
    @objc var scriptAudioLeftChannel: Int { get { prefs.audioLeftChannel } set { prefs.audioLeftChannel = max(1, newValue) } }
    @objc var scriptAudioRightChannel: Int { get { prefs.audioRightChannel } set { prefs.audioRightChannel = max(1, newValue) } }
    @objc var scriptAudioDelay: Int { get { prefs.audioDelayMs } set { prefs.audioDelayMs = newValue } }
    @objc var scriptAudioMonitoring: Bool { get { prefs.audioMonitorOn } set { prefs.audioMonitorOn = newValue } }
    @objc var scriptAudioMonitorVolume: Double { get { prefs.audioMonitorVolume } set { prefs.audioMonitorVolume = max(0, min(1, newValue)) } }

    // MARK: Image adjustments

    @objc var scriptBrightness: Double { get { prefs.brightness } set { prefs.brightness = clamp50(newValue) } }
    @objc var scriptContrast: Double { get { prefs.contrast } set { prefs.contrast = clamp50(newValue) } }
    @objc var scriptCb: Double { get { prefs.cbAdjust } set { prefs.cbAdjust = clamp50(newValue) } }
    @objc var scriptCr: Double { get { prefs.crAdjust } set { prefs.crAdjust = clamp50(newValue) } }
    @objc var scriptSaturation: Double { get { (prefs.cbAdjust + prefs.crAdjust) / 2 } set { prefs.cbAdjust = clamp50(newValue); prefs.crAdjust = clamp50(newValue) } }
    @objc var scriptSharpness: Double { get { prefs.sharpness } set { prefs.sharpness = clamp50(newValue) } }
    @objc var scriptTextOverlay: String { get { prefs.overlayText } set { prefs.overlayText = newValue } }
    @objc var scriptOverlayFontSize: Int { get { prefs.overlayFontSize } set { prefs.overlayFontSize = max(6, newValue) } }

    // MARK: Files

    @objc var scriptCaptureDestination: String {
        get { prefs.captureDestination }
        set {
            let path = (newValue as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { scriptError(7, "\"\(newValue)\" is not a folder."); return }
            prefs.captureDestination = path
        }
    }
    @objc var scriptFileNameFormat: String { get { prefs.fileNameFormat } set { prefs.fileNameFormat = newValue } }
    @objc var scriptAskWhereToSave: Bool { get { prefs.askWhereToSave } set { prefs.askWhereToSave = newValue } }
    @objc var scriptImageCaptureFormat: Int { get { prefs.imageCaptureFormat.rawValue } set { if let f = ImageFileFormat(rawValue: newValue) { prefs.imageCaptureFormat = f } } }
    @objc var scriptImageCopyFormat: Int { get { prefs.imageCopyFormat.rawValue } set { if let f = ImageFileFormat(rawValue: newValue) { prefs.imageCopyFormat = f } } }
    @objc var scriptImageCaptureSize: Int { get { prefs.imageCaptureSize.rawValue } set { if let s = ImageCaptureSize(rawValue: newValue) { prefs.imageCaptureSize = s } } }
    @objc var scriptClickSound: Bool { get { prefs.clickSound } set { prefs.clickSound = newValue } }

    // MARK: Timelapse / stop motion

    @objc var scriptTimelapseFrames: Int { get { prefs.timelapseFrames } set { prefs.timelapseFrames = max(1, newValue) } }
    @objc var scriptTimelapseInterval: Double { get { prefs.timelapseInterval } set { prefs.timelapseInterval = max(0.1, newValue) } }
    @objc var scriptTimelapsePlaybackRate: Double { get { prefs.timelapsePlaybackFPS } set { prefs.timelapsePlaybackFPS = max(1, newValue) } }
    @objc var scriptStopMotionAveraging: Int { get { prefs.stopMotionAveraging } set { prefs.stopMotionAveraging = max(1, newValue) } }
    @objc var scriptStopMotionPlaybackRate: Double { get { prefs.stopMotionPlaybackFPS } set { prefs.stopMotionPlaybackFPS = max(1, newValue) } }
    @objc var scriptOnionSkin: Bool { get { stopMotion?.onionSkin ?? false } set { stopMotion?.onionSkin = newValue } }

    // MARK: Encoding / window

    @objc var scriptVideoEncoding: Int { get { prefs.videoEncoding.rawValue } set { if let e = VideoEncoding(rawValue: newValue) { prefs.videoEncoding = e } } }
    @objc var scriptAudioEncoding: Int { get { prefs.audioEncoding.rawValue } set { if let e = AudioEncoding(rawValue: newValue) { prefs.audioEncoding = e } } }
    @objc var scriptFloatWindow: Bool { get { prefs.floatWindow } set { prefs.floatWindow = newValue } }
    @objc var scriptShowTitleBar: Bool { get { prefs.showTitleBar } set { prefs.showTitleBar = newValue } }
}
