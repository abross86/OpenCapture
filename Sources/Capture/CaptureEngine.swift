import AVFoundation
import Combine
import CoreImage
import AppKit

/// Receives processed video frames and remixed audio from the engine (recorders, timelapse, stop-motion...).
protocol FrameSink: AnyObject {
    func sinkVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime)
    func sinkAudio(_ sampleBuffer: CMSampleBuffer)
}

/// Owns the AVCaptureSession: device/format selection, frame processing, audio routing, monitoring and fan-out.
final class CaptureEngine: NSObject, ObservableObject {
    static let shared = CaptureEngine()

    let session = AVCaptureSession()
    let processor = FrameProcessor()

    // Published state (main thread)
    @Published private(set) var videoDevice: AVCaptureDevice?
    @Published private(set) var audioDevice: AVCaptureDevice?
    @Published private(set) var rawSize = CGSize.zero          // format size as delivered by the device
    @Published private(set) var videoSize = CGSize.zero        // after transformation
    @Published private(set) var nominalFPS: Double = 0
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var isVideoLive = false
    @Published private(set) var isAudioLive = false
    @Published private(set) var audioLevels: [Float] = []      // dB per channel, after routing
    @Published private(set) var lastVideoError = 0
    @Published private(set) var lastAudioError = 0

    /// Where live frames are shown. Set by the video window.
    weak var preview: MetalPreviewView?

    private let sessionQueue = DispatchQueue(label: "org.opencapture.session")
    private let videoQueue = DispatchQueue(label: "org.opencapture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "org.opencapture.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private var configSignature = ""
    private var cancellables = Set<AnyCancellable>()
    private var staleTimer: Timer?

    // Shared with capture threads
    private let frameLock = NSLock()
    private var _latest: CVPixelBuffer?
    private var sinks: [ObjectIdentifier: FrameSink] = [:]
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var lastLevelPublish = CACurrentMediaTime()
    private var lastAudioTime: CFTimeInterval = 0

    struct AudioRoute: Equatable { var left = 0; var right = 1; var stereo = true }
    private var _route = AudioRoute()
    private var route: AudioRoute { frameLock.lock(); defer { frameLock.unlock() }; return _route }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            ErrorLog.shared.log("Capture", "Session runtime error: \(err?.localizedDescription ?? "unknown")", code: err?.code ?? -1)
            self?.lastVideoError = err?.code ?? -1
            self?.sessionQueue.asyncAfter(deadline: .now() + 1) { if !(self?.session.isRunning ?? true) { self?.session.startRunning() } }
        }
        DeviceManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences(force: true) }
            .store(in: &cancellables)
        Prefs.shared.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &cancellables)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkStale() }
    }

    // MARK: Sinks

    func addSink(_ s: FrameSink) { frameLock.lock(); sinks[ObjectIdentifier(s)] = s; frameLock.unlock() }
    func removeSink(_ s: FrameSink) { frameLock.lock(); sinks.removeValue(forKey: ObjectIdentifier(s)); frameLock.unlock() }

    /// Most recent processed frame (for snapshots, stop-motion, onion skin).
    var latestFrame: CVPixelBuffer? { frameLock.lock(); defer { frameLock.unlock() }; return _latest }

    // MARK: Configuration

    /// Call after camera/microphone permission is granted. Re-applies on every preference change.
    func applyPreferences(force: Bool = false) {
        let p = Prefs.shared
        processor.settings = ProcessorSettings(prefs: p)
        frameLock.lock()
        _route = AudioRoute(left: max(0, p.audioLeftChannel - 1), right: max(0, p.audioRightChannel - 1), stereo: p.audioFormat.isStereo)
        frameLock.unlock()
        videoSize = processor.outputSize(for: rawSize)
        preview?.flipHorizontal = p.liveFlipHorizontal

        let sig = [p.videoDeviceID, p.videoFormatKey, "\(p.videoWidth)x\(p.videoHeight)@\(p.videoFrameRate)", "\(p.videoBufferSize)",
                   p.audioDeviceID, "\(p.audioFormat)"].joined(separator: "|")
        let vol = Float(p.audioMonitorVolume), mon = p.audioMonitorOn
        if force || sig != configSignature {
            configSignature = sig
            sessionQueue.async { self.configureSession(); self.updateMonitor(on: mon, volume: vol) }
        } else {
            sessionQueue.async { self.updateMonitor(on: mon, volume: vol) }
        }
    }

    private func configureSession() {
        let p = Prefs.shared
        let dm = DeviceManager.shared
        var vdev: AVCaptureDevice?, adev: AVCaptureDevice?
        var prefVideoID = "", prefAudioID = "", prefFormatKey = "", w = 0, h = 0, fps = 0.0
        var buffer = VideoBufferSize.medium, aformat = AudioFormat.stereo16_48
        DispatchQueue.main.sync {
            prefVideoID = p.videoDeviceID; prefAudioID = p.audioDeviceID; prefFormatKey = p.videoFormatKey
            w = p.videoWidth; h = p.videoHeight; fps = p.videoFrameRate; buffer = p.videoBufferSize; aformat = p.audioFormat
            vdev = dm.videoDevice(preferredID: prefVideoID)
            adev = dm.audioDevice(preferredID: prefAudioID)
        }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.filter { !($0 is AVCaptureAudioPreviewOutput) }.forEach { session.removeOutput($0) }

        var size = CGSize.zero, nominal = 0.0, videoErr = 0, audioErr = 0

        if let dev = vdev {
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                if session.canAddInput(input) { session.addInput(input) } else { throw NSError(domain: "OpenCapture", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]) }
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = (buffer == .none || buffer == .small)
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                // Setting activeFormat switches the session to input-priority mode on macOS, so the
                // format and frame rate chosen here are what the output receives. These setters throw
                // Objective-C exceptions for values the device rejects, so they run inside OCCatchException.
                try dev.lockForConfiguration()
                if let fmt = Self.chooseFormat(for: dev, key: prefFormatKey, width: w, height: h, fps: fps) {
                    if let err = OCCatchException({ dev.activeFormat = fmt }) {
                        ErrorLog.shared.log("Video", "Device refused format \(DeviceManager.formatLabel(fmt)): \(err.localizedDescription)", code: (err as NSError).code)
                    }
                    let active = dev.activeFormat
                    if let (duration, rate) = Self.chooseFrameDuration(for: active, requested: fps) {
                        if let err = OCCatchException({
                            dev.activeVideoMinFrameDuration = duration
                            dev.activeVideoMaxFrameDuration = duration
                        }) {
                            ErrorLog.shared.log("Video", "Device refused frame rate \(String(format: "%g", rate)): \(err.localizedDescription); using its default", code: (err as NSError).code)
                            _ = OCCatchException({ dev.activeVideoMinFrameDuration = .invalid; dev.activeVideoMaxFrameDuration = .invalid })
                            nominal = active.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                        } else { nominal = rate }
                    }
                    let d = CMVideoFormatDescriptionGetDimensions(active.formatDescription)
                    size = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
                }
                dev.unlockForConfiguration()
            } catch {
                let e = error as NSError
                videoErr = e.code
                ErrorLog.shared.log("Video", "Could not open \(dev.localizedName): \(e.localizedDescription)", code: e.code)
                vdev = nil
            }
        }

        if let dev = adev {
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                if session.canAddInput(input) { session.addInput(input) } else { throw NSError(domain: "OpenCapture", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"]) }
                let channels = DeviceManager.audioChannelCount(dev)
                audioOutput.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: aformat.sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            } catch {
                let e = error as NSError
                audioErr = e.code
                ErrorLog.shared.log("Audio", "Could not open \(dev.localizedName): \(e.localizedDescription)", code: e.code)
                adev = nil
            }
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }

        let vd = vdev, ad = adev, sz = size, nom = nominal
        DispatchQueue.main.async {
            self.videoDevice = vd; self.audioDevice = ad
            self.rawSize = sz; self.videoSize = self.processor.outputSize(for: sz); self.nominalFPS = nom
            if videoErr != 0 { self.lastVideoError = videoErr }
            if audioErr != 0 { self.lastAudioError = audioErr }
            if vd == nil { self.isVideoLive = false; self.preview?.display(image: nil) }
            if ad == nil { self.isAudioLive = false; self.audioLevels = [] }
            ErrorLog.shared.log("Capture", "Video: \(vd?.localizedName ?? "none") \(Int(sz.width))×\(Int(sz.height)) @ \(String(format: "%g", nom)) fps; Audio: \(ad?.localizedName ?? "none")")
        }
    }

    private func updateMonitor(on: Bool, volume: Float) {
        if on {
            if audioPreview == nil {
                let out = AVCaptureAudioPreviewOutput()
                session.beginConfiguration()
                if session.canAddOutput(out) { session.addOutput(out); audioPreview = out }
                session.commitConfiguration()
            }
            audioPreview?.volume = volume
        } else if let out = audioPreview {
            session.beginConfiguration(); session.removeOutput(out); session.commitConfiguration()
            audioPreview = nil
        }
    }

    static func chooseFormat(for dev: AVCaptureDevice, key: String, width: Int, height: Int, fps: Double) -> AVCaptureDevice.Format? {
        let formats = dev.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video }
        if !key.isEmpty, let f = formats.first(where: { DeviceManager.formatKey($0) == key }) { return f }
        var candidates = formats
        if width > 0 && height > 0 {
            let exact = candidates.filter { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return Int(d.width) == width && Int(d.height) == height }
            if !exact.isEmpty { candidates = exact }
        }
        if fps > 0 {
            let fast = candidates.filter { ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) >= fps - 0.01 }
            if !fast.isEmpty { candidates = fast }
        }
        // "Maximum" means the widest landscape format, then the most pixels, then the fastest.
        func score(_ f: AVCaptureDevice.Format) -> (Int, Int, Double) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (Int(d.width), Int(d.width) * Int(d.height), f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        return candidates.max { a, b in score(a) < score(b) }
    }

    /// Picks a frame duration the device will accept. Durations come from the device's own
    /// AVFrameRateRange values (exact CMTimes) rather than being recomputed from a Double, because
    /// e.g. 59.94 fps is 1001/60000 on the device and 1000/59940 when recomputed — close, but rejected.
    static func chooseFrameDuration(for fmt: AVCaptureDevice.Format, requested: Double) -> (CMTime, Double)? {
        let ranges = fmt.videoSupportedFrameRateRanges
        guard let fastest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
        if requested <= 0 { return (fastest.minFrameDuration, fastest.maxFrameRate) }
        if let r = ranges.first(where: { $0.minFrameRate - 0.01 <= requested && requested <= $0.maxFrameRate + 0.01 }) {
            if abs(requested - r.maxFrameRate) < 0.01 { return (r.minFrameDuration, r.maxFrameRate) }
            if abs(requested - r.minFrameRate) < 0.01 { return (r.maxFrameDuration, r.minFrameRate) }
            var d = CMTime(value: 1000, timescale: CMTimeScale(requested * 1000))
            if CMTimeCompare(d, r.minFrameDuration) < 0 { d = r.minFrameDuration }
            if CMTimeCompare(d, r.maxFrameDuration) > 0 { d = r.maxFrameDuration }
            return (d, requested)
        }
        // Outside every range: snap to the nearest supported edge.
        let edges = ranges.flatMap { [(rate: $0.minFrameRate, dur: $0.maxFrameDuration), (rate: $0.maxFrameRate, dur: $0.minFrameDuration)] }
        guard let e = edges.min(by: { abs($0.rate - requested) < abs($1.rate - requested) }) else { return nil }
        return (e.dur, e.rate)
    }

    private func checkStale() {
        let now = CACurrentMediaTime()
        if isVideoLive && now - lastFrameTime > 2 { isVideoLive = false; measuredFPS = 0 }
        if isAudioLive && now - lastAudioTime > 2 { isAudioLive = false; audioLevels = [] }
    }

    /// Current frame as a CIImage, with the live processing already applied (frames are post-processor).
    func snapshotImage() -> CIImage? { latestFrame.map { CIImage(cvPixelBuffer: $0) } }
}

// MARK: - Sample buffer delegates

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let processed = processor.process(pb)
            frameLock.lock()
            _latest = processed
            let targets = Array(sinks.values)
            frameLock.unlock()
            preview?.display(pixelBuffer: processed)
            for s in targets { s.sinkVideo(processed, pts: pts) }

            // FPS / liveness bookkeeping
            let now = CACurrentMediaTime()
            lastFrameTime = now
            fpsCount += 1
            if now - fpsWindowStart >= 1 {
                let fps = Double(fpsCount) / (now - fpsWindowStart)
                fpsCount = 0; fpsWindowStart = now
                DispatchQueue.main.async { self.measuredFPS = fps; if !self.isVideoLive { self.isVideoLive = true } }
            }
        } else if output === audioOutput {
            lastAudioTime = CACurrentMediaTime()
            let r = route
            let out = AudioRemixer.remix(sampleBuffer, left: r.left, right: r.right, stereo: r.stereo) ?? sampleBuffer
            frameLock.lock(); let targets = Array(sinks.values); frameLock.unlock()
            for s in targets { s.sinkAudio(out) }

            if lastAudioTime - lastLevelPublish > 0.07 {
                lastLevelPublish = lastAudioTime
                let levels = AudioRemixer.levels(of: out)
                DispatchQueue.main.async { self.audioLevels = levels; if !self.isAudioLive { self.isAudioLive = true } }
            }
        }
    }
}

// MARK: - Audio channel routing

enum AudioRemixer {
    /// Picks the configured input channels into a stereo (or mono) float32 interleaved buffer.
    /// Returns nil when the buffer can be used as-is.
    static func remix(_ sb: CMSampleBuffer, left: Int, right: Int, stereo: Bool) -> CMSampleBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        let inCh = Int(asbd.mChannelsPerFrame)
        let outCh = stereo ? 2 : 1
        let l = min(left, inCh - 1), r = min(right, inCh - 1)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard isFloat, interleaved, asbd.mBitsPerChannel == 32 else { return nil }
        if inCh == outCh && l == 0 && (outCh == 1 || r == 1) { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let base = ptr, length >= frames * inCh * 4 else { return nil }
        let src = UnsafeRawPointer(base).assumingMemoryBound(to: Float.self)
        var out = [Float](repeating: 0, count: frames * outCh)
        out.withUnsafeMutableBufferPointer { dst in
            for i in 0..<frames {
                dst[i * outCh] = src[i * inCh + l]
                if outCh == 2 { dst[i * outCh + 1] = src[i * inCh + r] }
            }
        }
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: asbd.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * outCh), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * outCh),
            mChannelsPerFrame: UInt32(outCh), mBitsPerChannel: 32, mReserved: 0)
        var outFD: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &outASBD, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &outFD) == noErr, let outFormat = outFD else { return nil }

        let byteCount = out.count * 4
        var outBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &outBlock) == noErr, let ob = outBlock else { return nil }
        out.withUnsafeBytes { raw in _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: ob, offsetIntoDestination: 0, dataLength: byteCount) }

        var result: CMSampleBuffer?
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: ob, formatDescription: outFormat, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    /// RMS level in dBFS per channel of a float32 interleaved buffer.
    static func levels(of sb: CMSampleBuffer) -> [Float] {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        let ch = Int(asbd.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(sb)
        var length = 0; var ptr: UnsafeMutablePointer<Int8>?
        guard frames > 0, ch > 0, CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let base = ptr, length >= frames * ch * 4 else { return [] }
        let src = UnsafeRawPointer(base).assumingMemoryBound(to: Float.self)
        var sums = [Float](repeating: 0, count: ch)
        for i in 0..<frames { for c in 0..<ch { let v = src[i * ch + c]; sums[c] += v * v } }
        return sums.map { s in let rms = (s / Float(frames)).squareRoot(); return max(-80, 20 * log10(max(rms, 1e-6))) }
    }
}
