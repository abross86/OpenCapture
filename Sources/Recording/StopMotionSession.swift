import AVFoundation
import CoreImage
import Accelerate
import Combine
import AppKit

/// Frame-by-frame capture. Frames live in memory as JPEG data; the movie is written when the
/// session ends. Supports frame averaging (noise reduction), onion skin, playback and undo/redo.
final class StopMotionSession: ObservableObject, FrameSink {
    let url: URL
    let size: CGSize
    let playbackFPS: Double
    let averagingCount: Int
    let undoManager = UndoManager()

    @Published private(set) var frames: [Data] = []
    @Published var selectedIndex = -1          // -1 = nothing selected (empty movie)
    @Published var isPlaying = false
    @Published var onionSkin = false
    @Published private(set) var isAveraging = false
    @Published private(set) var averagingProgress = 0.0
    @Published private(set) var isWriting = false

    private let lock = NSLock()
    private var pendingAverage = 0
    private var accumulator: [Float] = []
    private var accWidth = 0, accHeight = 0, accRowBytes = 0
    private var playTimer: Timer?
    private var imageCache: (Int, CGImage)?
    private var renderer: PixelBufferRenderer?

    init(url: URL, size: CGSize, prefs p: Prefs) {
        self.url = url; self.size = size
        playbackFPS = max(1, p.stopMotionPlaybackFPS)
        averagingCount = max(1, p.stopMotionAveraging)
        undoManager.levelsOfUndo = 200
    }

    var frameCount: Int { frames.count }
    var movieDuration: Double { Double(frames.count) / playbackFPS }

    // MARK: Loading an existing movie ("Continue…")

    func load(from movieURL: URL) throws {
        let reader = try MovieFrameReader(url: movieURL)
        var loaded: [Data] = []
        try reader.readFrames { pb, _ in
            if let cg = Self.cgImage(from: pb), let d = Self.jpegData(cg) { loaded.append(d) }
            return true
        }
        frames = loaded
        selectedIndex = frames.count - 1
    }

    // MARK: Capturing

    /// Captures the next frame from the live video (Return key / AppleScript). Returns false if busy.
    @discardableResult
    func captureFrame() -> Bool {
        guard !isAveraging, !isWriting else { return false }
        if averagingCount <= 1 {
            guard let pb = CaptureEngine.shared.latestFrame, let cg = Self.cgImage(from: pb), let d = Self.jpegData(cg) else { return false }
            addFrame(d)
            return true
        }
        lock.lock()
        pendingAverage = averagingCount
        accumulator = []
        lock.unlock()
        isAveraging = true; averagingProgress = 0
        return true
    }

    func sinkVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard pendingAverage > 0 else { lock.unlock(); return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer), rb = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { lock.unlock(); return }
        let n = rb * h
        if accumulator.isEmpty || accWidth != w || accHeight != h || accRowBytes != rb {
            accumulator = [Float](repeating: 0, count: n); accWidth = w; accHeight = h; accRowBytes = rb
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var tmp = [Float](repeating: 0, count: n)
        vDSP_vfltu8(bytes, 1, &tmp, 1, vDSP_Length(n))
        vDSP_vadd(accumulator, 1, tmp, 1, &accumulator, 1, vDSP_Length(n))
        pendingAverage -= 1
        let remaining = pendingAverage
        let done = remaining == 0
        var result: Data?
        if done {
            var divisor = Float(averagingCount)
            vDSP_vsdiv(accumulator, 1, &divisor, &accumulator, 1, vDSP_Length(n))
            var out = [UInt8](repeating: 0, count: n)
            vDSP_vfixru8(accumulator, 1, &out, 1, vDSP_Length(n))
            accumulator = []
            result = out.withUnsafeMutableBytes { raw -> Data? in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      let cg = ctx.makeImage() else { return nil }
                return Self.jpegData(cg)
            }
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.averagingProgress = 1 - Double(remaining) / Double(self.averagingCount)
            if done {
                self.isAveraging = false
                if let result { self.addFrame(result) }
            }
        }
    }
    func sinkAudio(_ sampleBuffer: CMSampleBuffer) {}

    // MARK: Frame list with undo

    func addFrame(_ data: Data) {
        frames.append(data)
        selectedIndex = frames.count - 1
        undoManager.registerUndo(withTarget: self) { s in s.removeLastFrame() }
        undoManager.setActionName("Add Frame")
        if Prefs.shared.clickSound { ImageCapture.playClick() }
    }

    func removeLastFrame() {
        guard let last = frames.popLast() else { return }
        selectedIndex = min(selectedIndex, frames.count - 1)
        imageCache = nil
        undoManager.registerUndo(withTarget: self) { s in s.addFrame(last) }
        undoManager.setActionName("Add Frame")
    }

    func deleteSelectedFrame() {
        guard frames.indices.contains(selectedIndex) else { return }
        let idx = selectedIndex, data = frames.remove(at: idx)
        selectedIndex = min(idx, frames.count - 1)
        imageCache = nil
        undoManager.registerUndo(withTarget: self) { s in s.insertFrame(data, at: idx) }
        undoManager.setActionName("Delete Frame")
    }

    private func insertFrame(_ data: Data, at idx: Int) {
        frames.insert(data, at: min(idx, frames.count))
        selectedIndex = idx
        imageCache = nil
        undoManager.registerUndo(withTarget: self) { s in s.deleteFrame(at: idx) }
        undoManager.setActionName("Delete Frame")
    }
    private func deleteFrame(at idx: Int) { selectedIndex = idx; deleteSelectedFrame() }

    func image(at index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        if let c = imageCache, c.0 == index { return c.1 }
        guard let cg = Self.decode(frames[index]) else { return nil }
        imageCache = (index, cg)
        return cg
    }

    // MARK: Playback

    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        guard frames.count > 1 else { return }
        isPlaying = true
        if selectedIndex >= frames.count - 1 { selectedIndex = 0 }
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / playbackFPS, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.selectedIndex + 1 >= self.frames.count { self.stopPlayback(); self.selectedIndex = self.frames.count - 1 }
            else { self.selectedIndex += 1 }
        }
    }
    func stopPlayback() { playTimer?.invalidate(); playTimer = nil; isPlaying = false }

    // MARK: Output

    /// Writes the movie. Stop-motion never uses temporal compression (keeps frames independent).
    func finish(prefs p: Prefs, completion: @escaping (Error?) -> Void) {
        stopPlayback()
        let frames = self.frames
        isWriting = true
        let encoding: VideoEncoding = p.videoEncoding.isTemporallyCompressed ? .jpegHigh : p.videoEncoding
        let cfg = RecordingConfig(prefs: p, hasAudio: false, fps: playbackFPS, videoOverride: encoding)
        let fps = playbackFPS, size = self.size, url = self.url
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
                let rec = try MovieRecorder(url: tmp, size: size, config: cfg, realTime: false)
                let renderer = PixelBufferRenderer(size: size)
                for (i, d) in frames.enumerated() {
                    guard let cg = Self.decode(d), let pb = renderer.render(CIImage(cgImage: cg)) else { continue }
                    rec.appendVideo(pb, pts: CMTime(value: Int64(i) * 1000, timescale: CMTimeScale(fps * 1000)), wait: true)
                }
                let sem = DispatchSemaphore(value: 0)
                var err: Error?
                rec.finish { e in err = e; sem.signal() }
                sem.wait()
                if err == nil {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
                DispatchQueue.main.async { self.isWriting = false; completion(err) }
            } catch {
                DispatchQueue.main.async { self.isWriting = false; completion(error) }
            }
        }
    }

    func exportStills(to folder: URL, format: ImageFileFormat, completion: @escaping (Error?) -> Void) {
        let frames = self.frames
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (i, d) in frames.enumerated() {
                    let name = String(format: "frame-%05d.%@", i + 1, format.fileExtension)
                    if format == .jpeg { try d.write(to: folder.appendingPathComponent(name)) }
                    else if let cg = Self.decode(d), let out = ImageCapture.encode(cg, format: format) { try out.write(to: folder.appendingPathComponent(name)) }
                }
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }

    // MARK: Codec helpers

    static func cgImage(from pb: CVPixelBuffer) -> CGImage? {
        FrameProcessorShared.context.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
    }
    static func jpegData(_ cg: CGImage) -> Data? { ImageCapture.encode(cg, format: .jpeg, quality: 0.95) }
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// One shared CIContext for off-thread CGImage creation.
enum FrameProcessorShared {
    static let context: CIContext = {
        if let d = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: d, options: [.cacheIntermediates: false]) }
        return CIContext()
    }()
}
