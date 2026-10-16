import MetalKit
import CoreImage

/// Metal-backed video preview. Frames are handed in from any thread; drawing happens on the
/// view's display link (main thread) and only when a new frame or overlay is pending.
class MetalPreviewView: MTKView {
    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var image: CIImage?
    private var dirty = true

    /// Mirror the live view horizontally (display only).
    var flipHorizontal = false { didSet { markDirty() } }
    /// Optional overlay (e.g. onion-skin live image) composited over `image` at `overlayAlpha`.
    var overlayProvider: (() -> CIImage?)?
    var overlayAlpha: CGFloat = 0.5

    override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        commandQueue = dev.makeCommandQueue()!
        super.init(frame: frame, device: dev)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    }
    required init(coder: NSCoder) { fatalError() }

    func display(pixelBuffer: CVPixelBuffer) { display(image: CIImage(cvPixelBuffer: pixelBuffer)) }

    func display(image: CIImage?) {
        lock.lock(); self.image = image; dirty = true; lock.unlock()
    }

    func markDirty() { lock.lock(); dirty = true; lock.unlock() }

    override func layout() { super.layout(); markDirty() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); markDirty() }

    override func draw(_ dirtyRect: NSRect) {
        lock.lock()
        let img = image
        let needs = dirty
        dirty = false
        lock.unlock()
        let overlay = overlayProvider?()
        guard needs || overlay != nil else { return }
        guard drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable, let cb = commandQueue.makeCommandBuffer() else { return }

        let target = CGRect(origin: .zero, size: drawableSize)
        var out = CIImage(color: .black).cropped(to: target)
        if let img { out = Self.fit(img, into: target).composited(over: out) }
        if let overlay {
            let a = overlayAlpha
            let faded = Self.fit(overlay, into: target).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
            out = faded.composited(over: out)
        }
        if flipHorizontal {
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -target.width, y: 0)).cropped(to: target)
        }
        ciContext.render(out, to: drawable.texture, commandBuffer: cb, bounds: target, colorSpace: CGColorSpaceCreateDeviceRGB())
        cb.present(drawable)
        cb.commit()
    }

    static func fit(_ img: CIImage, into target: CGRect) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        let s = min(target.width / e.width, target.height / e.height)
        let w = e.width * s, h = e.height * s
        let t = CGAffineTransform(translationX: (target.width - w) / 2, y: (target.height - h) / 2)
            .scaledBy(x: s, y: s).translatedBy(x: -e.minX, y: -e.minY)
        return img.transformed(by: t)
    }
}
