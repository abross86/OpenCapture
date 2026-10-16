import AVFoundation
import CoreImage

struct RecordingConfig {
    var videoEncoding: VideoEncoding
    var audioEncoding: AudioEncoding
    var audioFormat: AudioFormat
    var hasAudio: Bool
    var audioDelayMs: Int
    var fps: Double

    init(prefs p: Prefs, hasAudio: Bool, fps: Double, videoOverride: VideoEncoding? = nil) {
        videoEncoding = videoOverride ?? p.videoEncoding
        audioEncoding = p.audioEncoding
        audioFormat = p.audioFormat
        self.hasAudio = hasAudio
        audioDelayMs = p.audioDelayMs
        self.fps = fps > 0 ? fps : 30
    }

    /// MP4 only when H.264/H.265 with AAC (or no audio); everything else goes in a QuickTime container.
    var fileType: AVFileType { videoEncoding.isTemporallyCompressed && (!hasAudio || audioEncoding.isAAC) ? .mp4 : .mov }
    var fileExtension: String { fileType == .mp4 ? "mp4" : "mov" }

    func videoSettings(size: CGSize) -> [String: Any] {
        let w = Int(size.width), h = Int(size.height)
        var s: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h]
        let pixelsPerSecond = Double(w * h) * fps
        switch videoEncoding {
        case .h264Low, .h264Medium, .h264High:
            let bpp = [0.045, 0.09, 0.18][videoEncoding.rawValue]
            s[AVVideoCodecKey] = AVVideoCodecType.h264
            s[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: Int(pixelsPerSecond * bpp),
                                                  AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                                  AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                                                  AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
                                                  AVVideoAllowFrameReorderingKey: true]
        case .h265Low, .h265Medium, .h265High:
            let bpp = [0.03, 0.06, 0.12][videoEncoding.rawValue - VideoEncoding.h265Low.rawValue]
            s[AVVideoCodecKey] = AVVideoCodecType.hevc
            s[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: Int(pixelsPerSecond * bpp),
                                                  AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                                                  AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded())]
        case .jpegHigh:
            s[AVVideoCodecKey] = AVVideoCodecType.jpeg
            s[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.9]
        case .proResLT: s[AVVideoCodecKey] = AVVideoCodecType.proRes422LT
        case .proRes: s[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .proResHQ: s[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        }
        return s
    }

    func audioSettings() -> [String: Any] {
        let ch = audioFormat.channels
        if audioEncoding.isAAC {
            let perStereo = [64_000, 128_000, 256_000][audioEncoding.rawValue]
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioFormat.sampleRate, AVNumberOfChannelsKey: ch,
                    AVEncoderBitRateKey: ch == 1 ? perStereo / 2 : perStereo]
        }
        return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audioFormat.sampleRate, AVNumberOfChannelsKey: ch,
                AVLinearPCMBitDepthKey: audioFormat.bitDepth, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }
}

/// AVAssetWriter wrapper. Real-time mode drops frames when the encoder is busy; synthetic mode
/// (timelapse / stop-motion writing) blocks until the writer is ready so no frame is lost.
final class MovieRecorder: FrameSink {
    let url: URL
    let size: CGSize
    let config: RecordingConfig
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var sessionStart: CMTime?
    private var lastVideoPTS: CMTime = .zero
    private let audioOffset: CMTime
    private let videoOffset: CMTime
    private var finished = false
    private(set) var frameCount = 0
    private(set) var droppedFrames = 0
    private var sizeCache: (Date, Int64) = (.distantPast, 0)

    init(url: URL, size: CGSize, config: RecordingConfig, realTime: Bool) throws {
        self.url = url; self.size = size; self.config = config
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: config.fileType)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: config.videoSettings(size: size))
        videoInput.expectsMediaDataInRealTime = realTime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(videoInput) else { throw NSError(domain: "OpenCapture", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Cannot add video track"]) }
        writer.add(videoInput)
        if config.hasAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: config.audioSettings())
            a.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(a) else { throw NSError(domain: "OpenCapture", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio track"]) }
            writer.add(a); audioInput = a
        } else { audioInput = nil }
        let delay = CMTime(value: CMTimeValue(abs(config.audioDelayMs)), timescale: 1000)
        audioOffset = config.audioDelayMs > 0 ? delay : .zero
        videoOffset = config.audioDelayMs < 0 ? delay : .zero
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "OpenCapture", code: 2003, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"]) }
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        guard let s = sessionStart else { return 0 }
        return max(0, CMTimeGetSeconds(lastVideoPTS - s))
    }

    /// File size on disk, refreshed at most twice a second.
    var fileSize: Int64 {
        if Date().timeIntervalSince(sizeCache.0) > 0.5 {
            let s = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            sizeCache = (Date(), s)
        }
        return sizeCache.1
    }

    // MARK: FrameSink (real-time path)

    func sinkVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) { appendVideo(pixelBuffer, pts: pts + videoOffset, wait: false) }

    func sinkAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput else { return }
        lock.lock(); defer { lock.unlock() }
        guard !finished, let start = sessionStart, writer.status == .writing else { return }
        guard let sb = Self.retime(sampleBuffer, by: audioOffset) else { return }
        if CMSampleBufferGetPresentationTimeStamp(sb) < start { return }
        if audioInput.isReadyForMoreMediaData { audioInput.append(sb) }
    }

    /// Appends a frame with an explicit timestamp. `wait` blocks until the writer is ready (synthetic timing).
    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, wait: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        guard CVPixelBufferGetWidth(pixelBuffer) == Int(size.width), CVPixelBufferGetHeight(pixelBuffer) == Int(size.height) else { droppedFrames += 1; return }
        if sessionStart == nil { sessionStart = pts; writer.startSession(atSourceTime: pts) }
        if pts <= lastVideoPTS && frameCount > 0 { droppedFrames += 1; return }
        if !videoInput.isReadyForMoreMediaData {
            if !wait { droppedFrames += 1; return }
            while !videoInput.isReadyForMoreMediaData && writer.status == .writing { usleep(2000) }
        }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) { frameCount += 1; lastVideoPTS = pts }
        else { droppedFrames += 1 }
    }

    func finish(_ completion: @escaping (Error?) -> Void) {
        lock.lock()
        if finished { lock.unlock(); completion(nil); return }
        finished = true
        let started = sessionStart != nil
        lock.unlock()
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(writer.error ?? NSError(domain: "OpenCapture", code: 2004, userInfo: [NSLocalizedDescriptionKey: "No frames were recorded"]))
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer] in completion(writer.status == .completed ? nil : writer.error) }
    }

    static func retime(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr else { return nil }
        for i in 0..<count {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp + offset
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = infos[i].decodeTimeStamp + offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }
}

/// Reads the video frames of an existing movie as BGRA pixel buffers (for "Continue…" captures).
final class MovieFrameReader {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let size: CGSize
    let nominalFrameRate: Double

    init(url: URL) throws {
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "OpenCapture", code: 3001, userInfo: [NSLocalizedDescriptionKey: "No video track in \(url.lastPathComponent)"])
        }
        track = t
        let s = t.naturalSize.applying(t.preferredTransform)
        size = CGSize(width: abs(s.width), height: abs(s.height))
        nominalFrameRate = Double(t.nominalFrameRate)
    }

    /// Calls `body` for every frame in order. Return false from `body` to stop early.
    func readFrames(_ body: (CVPixelBuffer, CMTime) -> Bool) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "OpenCapture", code: 3002, userInfo: [NSLocalizedDescriptionKey: "Cannot read movie"]) }
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if !body(pb, CMSampleBufferGetPresentationTimeStamp(sb)) { reader.cancelReading(); return }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "OpenCapture", code: 3003, userInfo: [NSLocalizedDescriptionKey: "Movie read failed"]) }
    }
}
