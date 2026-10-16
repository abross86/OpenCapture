import AVFoundation
import CoreImage

/// Captures `framesPerCapture` frames every `interval` seconds and writes them with synthetic
/// timestamps so the movie plays back at `playbackFPS`.
final class TimelapseSession: FrameSink {
    let recorder: MovieRecorder
    let playbackFPS: Double
    let framesPerCapture: Int
    let interval: Double
    private let lock = NSLock()
    private var wanted = 0
    private var frameIndex: Int64 = 0
    private var timer: Timer?
    private var renderer: PixelBufferRenderer?

    var frameCount: Int { recorder.frameCount }
    var movieDuration: Double { Double(frameIndex) / playbackFPS }

    init(url: URL, size: CGSize, prefs p: Prefs) throws {
        playbackFPS = max(1, p.timelapsePlaybackFPS)
        framesPerCapture = max(1, p.timelapseFrames)
        interval = max(0.1, p.timelapseInterval)
        let cfg = RecordingConfig(prefs: p, hasAudio: false, fps: playbackFPS)
        recorder = try MovieRecorder(url: url, size: size, config: cfg, realTime: true)
    }

    /// Re-encodes the frames of an existing movie before live capture continues.
    func preload(from url: URL) throws {
        let reader = try MovieFrameReader(url: url)
        if renderer == nil { renderer = PixelBufferRenderer(size: recorder.size) }
        try reader.readFrames { pb, _ in
            let buf: CVPixelBuffer?
            if CVPixelBufferGetWidth(pb) == Int(self.recorder.size.width) && CVPixelBufferGetHeight(pb) == Int(self.recorder.size.height) { buf = pb }
            else { buf = self.renderer?.render(CIImage(cvPixelBuffer: pb)) }
            if let buf { self.recorder.appendVideo(buf, pts: self.nextPTS(), wait: true) }
            return true
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() { lock.lock(); wanted = framesPerCapture; lock.unlock() }

    private func nextPTS() -> CMTime {
        let t = CMTime(value: frameIndex * 1000, timescale: CMTimeScale(playbackFPS * 1000))
        frameIndex += 1
        return t
    }

    func sinkVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard wanted > 0 else { lock.unlock(); return }
        wanted -= 1
        let t = nextPTS()
        lock.unlock()
        recorder.appendVideo(pixelBuffer, pts: t, wait: true)
    }
    func sinkAudio(_ sampleBuffer: CMSampleBuffer) {}

    func stop(_ completion: @escaping (Error?) -> Void) {
        timer?.invalidate(); timer = nil
        recorder.finish(completion)
    }
}
