import AVFoundation
import Combine

/// Discovers video and audio capture devices and tracks hot-plug events (capture cards come and go).
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var videoDevices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let dev = note.object as? AVCaptureDevice
                ErrorLog.shared.log("Devices", "\(name == AVCaptureDevice.wasConnectedNotification ? "Connected" : "Disconnected"): \(dev?.localizedName ?? "unknown device")")
                self?.refresh()
            })
        }
    }

    func refresh() {
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        // Capture cards first, then built-in cameras, then iPhone (Continuity) and Desk View cameras,
        // which only deliver frames while the phone is awake and must be chosen explicitly.
        let v = video.sorted { (Self.rank($0), $0.localizedName) < (Self.rank($1), $1.localizedName) }
        let a = audio.sorted { $0.localizedName < $1.localizedName }
        // Only publish when something actually changed, so the session is not rebuilt needlessly.
        if v.map(\.uniqueID) != videoDevices.map(\.uniqueID) { videoDevices = v }
        if a.map(\.uniqueID) != audioDevices.map(\.uniqueID) { audioDevices = a }
    }

    static func rank(_ d: AVCaptureDevice) -> Int {
        switch d.deviceType {
        case .external: return 0
        case .builtInWideAngleCamera: return 1
        default: return 2
        }
    }
    static func isAutoSelectable(_ d: AVCaptureDevice) -> Bool { rank(d) < 2 }

    func videoDevice(preferredID: String) -> AVCaptureDevice? {
        if !preferredID.isEmpty, let d = videoDevices.first(where: { $0.uniqueID == preferredID }) { return d }
        return videoDevices.first(where: Self.isAutoSelectable) ?? videoDevices.first
    }

    func audioDevice(preferredID: String) -> AVCaptureDevice? {
        if preferredID == "none" { return nil }
        if !preferredID.isEmpty, let d = audioDevices.first(where: { $0.uniqueID == preferredID }) { return d }
        return audioDevices.first
    }

    // MARK: Format helpers

    static func formatKey(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(d.width)x\(d.height):\(fourCC(sub)):\(String(format: "%.2f", maxFPS))"
    }

    static func formatLabel(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let ranges = f.videoSupportedFrameRateRanges
        let fps: String
        if let lo = ranges.map(\.minFrameRate).min(), let hi = ranges.map(\.maxFrameRate).max() {
            fps = lo == hi ? String(format: "%g fps", hi) : String(format: "%g–%g fps", lo, hi)
        } else { fps = "" }
        return "\(d.width) × \(d.height)  \(codecName(sub))  \(fps)"
    }

    static func codecName(_ sub: FourCharCode) -> String {
        switch sub {
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: return "MJPEG"
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: return "YUV 4:2:2"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8Planar: return "YUV 4:2:0"
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB: return "RGB"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default: return fourCC(sub)
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    static func audioChannelCount(_ device: AVCaptureDevice) -> Int {
        guard let fd = device.activeFormat.formatDescription as CMFormatDescription?,
              CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return 2 }
        return max(1, Int(asbd.pointee.mChannelsPerFrame))
    }
}
