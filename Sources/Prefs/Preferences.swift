import Foundation
import Combine
import AVFoundation

// MARK: - Enumerations (raw values match the SwiftCapture AppleScript dictionary)

enum VideoEncoding: Int, CaseIterable, Identifiable {
    case h264Low = 0, h264Medium, h264High, jpegHigh, proResLT, proRes, proResHQ, h265Low, h265Medium, h265High
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .h264Low: return "H.264 low quality"
        case .h264Medium: return "H.264 medium quality"
        case .h264High: return "H.264 high quality"
        case .jpegHigh: return "JPEG high quality"
        case .proResLT: return "Apple ProRes 422 LT"
        case .proRes: return "Apple ProRes 422"
        case .proResHQ: return "Apple ProRes 422 HQ"
        case .h265Low: return "H.265 low quality"
        case .h265Medium: return "H.265 medium quality"
        case .h265High: return "H.265 high quality"
        }
    }
    var isTemporallyCompressed: Bool {
        switch self { case .h264Low, .h264Medium, .h264High, .h265Low, .h265Medium, .h265High: return true; default: return false }
    }
}

enum AudioEncoding: Int, CaseIterable, Identifiable {
    case aacLow = 0, aacMedium, aacHigh, uncompressed
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .aacLow: return "AAC low quality"
        case .aacMedium: return "AAC medium quality"
        case .aacHigh: return "AAC high quality"
        case .uncompressed: return "Uncompressed"
        }
    }
    var isAAC: Bool { self != .uncompressed }
}

enum AudioFormat: Int, CaseIterable, Identifiable {
    case mono16_44 = 0, stereo16_44, mono16_48, stereo16_48, mono24_44, stereo24_44, mono24_48, stereo24_48
    var id: Int { rawValue }
    var isStereo: Bool { rawValue % 2 == 1 }
    var channels: Int { isStereo ? 2 : 1 }
    var sampleRate: Double { (rawValue / 2) % 2 == 1 ? 48000 : 44100 }
    var bitDepth: Int { rawValue >= 4 ? 24 : 16 }
    var label: String { "\(isStereo ? "Stereo" : "Mono"), \(bitDepth) bit, \(sampleRate == 48000 ? "48" : "44.1") kHz" }
}

enum VideoTransform: Int, CaseIterable, Identifiable {
    case none = 0, flipHorizontal, flipVertical, rotate90, rotate180, rotate270
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .rotate90: return "Rotate 90° Right"
        case .rotate180: return "Rotate 180°"
        case .rotate270: return "Rotate 90° Left"
        }
    }
    var swapsDimensions: Bool { self == .rotate90 || self == .rotate270 }
}

enum VideoBufferSize: Int, CaseIterable, Identifiable {
    case none = 0, small, medium, large
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: return "None - best for low latency"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large - best for avoiding dropped frames"
        }
    }
}

enum ImageCaptureSize: Int, CaseIterable, Identifiable {
    case full = 0, half, quarter
    var id: Int { rawValue }
    var label: String { ["Full size", "Half size", "Quarter size"][rawValue] }
    var scale: CGFloat { [1, 0.5, 0.25][rawValue] }
}

enum ImageFileFormat: Int, CaseIterable, Identifiable {
    case jpeg = 0, png, tiff
    var id: Int { rawValue }
    var label: String { ["JPEG", "PNG", "TIFF"][rawValue] }
    var fileExtension: String { ["jpg", "png", "tiff"][rawValue] }
}

enum TitleBarButton: Int, CaseIterable, Identifiable {
    case none = 0, saveImage, recordMovie
    var id: Int { rawValue }
    var label: String { ["None", "Save Image", "Record Movie"][rawValue] }
}

// MARK: - UserDefaults-backed property wrappers

@propertyWrapper
struct Stored<Value> {
    let key: String
    let defaultValue: Value
    init(_ key: String, _ defaultValue: Value) { self.key = key; self.defaultValue = defaultValue }

    @available(*, unavailable, message: "Stored can only be used inside an ObservableObject")
    var wrappedValue: Value { get { fatalError() } set { fatalError() } }

    static subscript<E: ObservableObject>(
        _enclosingInstance instance: E,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<E, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<E, Self>
    ) -> Value where E.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let w = instance[keyPath: storageKeyPath]
            return (UserDefaults.standard.object(forKey: w.key) as? Value) ?? w.defaultValue
        }
        set {
            instance.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: instance[keyPath: storageKeyPath].key)
        }
    }
}

@propertyWrapper
struct StoredEnum<Value: RawRepresentable> {
    let key: String
    let defaultValue: Value
    init(_ key: String, _ defaultValue: Value) { self.key = key; self.defaultValue = defaultValue }

    @available(*, unavailable, message: "StoredEnum can only be used inside an ObservableObject")
    var wrappedValue: Value { get { fatalError() } set { fatalError() } }

    static subscript<E: ObservableObject>(
        _enclosingInstance instance: E,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<E, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<E, Self>
    ) -> Value where E.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let w = instance[keyPath: storageKeyPath]
            if let raw = UserDefaults.standard.object(forKey: w.key) as? Value.RawValue, let v = Value(rawValue: raw) { return v }
            return w.defaultValue
        }
        set {
            instance.objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: instance[keyPath: storageKeyPath].key)
        }
    }
}

// MARK: - Preferences

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private init() {}

    // Video input
    @Stored("videoDeviceID", "") var videoDeviceID: String            // "" = first available
    @Stored("videoFormatKey", "") var videoFormatKey: String          // "" = automatic
    @Stored("videoWidth", 0) var videoWidth: Int                      // 0 = maximum
    @Stored("videoHeight", 0) var videoHeight: Int
    @Stored("videoFrameRate", 0.0) var videoFrameRate: Double         // 0 = maximum
    @StoredEnum("videoBufferSize", VideoBufferSize.medium) var videoBufferSize: VideoBufferSize
    @StoredEnum("videoTransform", VideoTransform.none) var videoTransform: VideoTransform
    @Stored("liveFlipHorizontal", false) var liveFlipHorizontal: Bool

    // Audio input
    @Stored("audioDeviceID", "") var audioDeviceID: String            // "" = first, "none" = disabled
    @StoredEnum("audioFormat", AudioFormat.stereo16_48) var audioFormat: AudioFormat
    @Stored("audioLeftChannel", 1) var audioLeftChannel: Int          // 1-based input channel numbers
    @Stored("audioRightChannel", 2) var audioRightChannel: Int
    @Stored("audioDelayMs", 0) var audioDelayMs: Int
    @Stored("audioMonitorOn", false) var audioMonitorOn: Bool
    @Stored("audioMonitorVolume", 1.0) var audioMonitorVolume: Double

    // Image adjustments (-50 ... 50)
    @Stored("brightness", 0.0) var brightness: Double
    @Stored("contrast", 0.0) var contrast: Double
    @Stored("cbAdjust", 0.0) var cbAdjust: Double
    @Stored("crAdjust", 0.0) var crAdjust: Double
    @Stored("sharpness", 0.0) var sharpness: Double

    // Files
    @Stored("fileNameFormat", "+Y-+M-+D +h-+m-+s") var fileNameFormat: String
    @Stored("askWhereToSave", false) var askWhereToSave: Bool
    @Stored("captureDestination", NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? NSHomeDirectory()) var captureDestination: String
    @StoredEnum("imageCaptureSize", ImageCaptureSize.full) var imageCaptureSize: ImageCaptureSize
    @StoredEnum("imageCaptureFormat", ImageFileFormat.jpeg) var imageCaptureFormat: ImageFileFormat
    @StoredEnum("imageCopyFormat", ImageFileFormat.tiff) var imageCopyFormat: ImageFileFormat
    @Stored("clickSound", true) var clickSound: Bool

    // Overlay
    @Stored("overlayText", "") var overlayText: String
    @Stored("overlayFontSize", 16) var overlayFontSize: Int

    // Timelapse / stop-motion
    @Stored("timelapseFrames", 1) var timelapseFrames: Int
    @Stored("timelapseInterval", 10.0) var timelapseInterval: Double
    @Stored("timelapsePlaybackFPS", 30.0) var timelapsePlaybackFPS: Double
    @Stored("stopMotionAveraging", 1) var stopMotionAveraging: Int
    @Stored("stopMotionPlaybackFPS", 30.0) var stopMotionPlaybackFPS: Double

    // Encoding
    @StoredEnum("videoEncoding", VideoEncoding.h264Medium) var videoEncoding: VideoEncoding
    @StoredEnum("audioEncoding", AudioEncoding.aacMedium) var audioEncoding: AudioEncoding

    // Window
    @StoredEnum("titleBarButton", TitleBarButton.none) var titleBarButton: TitleBarButton
    @Stored("floatWindow", false) var floatWindow: Bool
    @Stored("showTitleBar", true) var showTitleBar: Bool
    @Stored("recordingLimitSeconds", 60) var recordingLimitSeconds: Int

    var captureDestinationURL: URL { URL(fileURLWithPath: captureDestination, isDirectory: true) }
}

// MARK: - File-name / overlay token expansion ("+Y-+M-+D +h-+m-+s")

enum TokenFormatter {
    static func expand(_ format: String, date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        var out = ""
        var it = format.makeIterator()
        while let ch = it.next() {
            guard ch == "+", let t = it.next() else { out.append(ch); continue }
            switch t {
            case "Y": out += String(c.year ?? 0)
            case "y": out += two((c.year ?? 0) % 100)
            case "M": out += two(c.month)
            case "D": out += two(c.day)
            case "h": out += two(c.hour)
            case "m": out += two(c.minute)
            case "s": out += two(c.second)
            default: out.append("+"); out.append(t)
            }
        }
        return out
    }
    static func containsTimeTokens(_ format: String) -> Bool {
        format.range(of: #"\+[YyMDhms]"#, options: .regularExpression) != nil
    }
    /// Expands the configured name format and makes it unique inside `directory`.
    static func uniqueFileURL(in directory: URL, format: String, ext: String) -> URL {
        var base = expand(format).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "Capture" }
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
        }
        return url
    }
}
