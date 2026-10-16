import CoreImage
import CoreVideo
import CoreText
import AppKit

/// Snapshot of the image-affecting preferences, pushed from the main thread and read on the video queue.
struct ProcessorSettings: Equatable {
    var transform: VideoTransform = .none
    var brightness = 0.0, contrast = 0.0, cb = 0.0, cr = 0.0, sharpness = 0.0   // -50 ... 50
    var overlayText = ""
    var overlayFontSize = 16

    init() {}
    init(prefs p: Prefs) {
        transform = p.videoTransform
        brightness = p.brightness; contrast = p.contrast; cb = p.cbAdjust; cr = p.crAdjust; sharpness = p.sharpness
        overlayText = p.overlayText; overlayFontSize = max(6, p.overlayFontSize)
    }
    var hasAdjustments: Bool { brightness != 0 || contrast != 0 || cb != 0 || cr != 0 || sharpness != 0 }
    var isIdentity: Bool { transform == .none && !hasAdjustments && overlayText.isEmpty }
}

/// Applies the video transformation, colour adjustments and text overlay to captured frames.
/// When nothing is configured the input pixel buffer is passed through untouched (zero cost).
final class FrameProcessor {
    private let lock = NSLock()
    private var _settings = ProcessorSettings()
    var settings: ProcessorSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    let ciContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var overlayCacheKey = ""
    private var overlayImage: CIImage?

    func outputSize(for input: CGSize) -> CGSize {
        settings.transform.swapsDimensions ? CGSize(width: input.height, height: input.width) : input
    }

    /// Returns the processed frame, or `input` itself if no processing is configured.
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer {
        let s = settings
        if s.isIdentity { return input }
        var img = CIImage(cvPixelBuffer: input)
        img = Self.apply(settings: s, to: img, overlay: overlay(for: s))
        let size = CGSize(width: img.extent.width.rounded(), height: img.extent.height.rounded())
        guard let out = makeBuffer(size: size) else { return input }
        ciContext.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        CVBufferPropagateAttachments(input, out)
        return out
    }

    /// The same pipeline, usable on any CIImage (used for still-image capture so snapshots match the live view).
    static func apply(settings s: ProcessorSettings, to image: CIImage, overlay: CIImage?) -> CIImage {
        var img = image
        switch s.transform {
        case .none: break
        case .flipHorizontal: img = img.oriented(.upMirrored)
        case .flipVertical: img = img.oriented(.downMirrored)
        case .rotate90: img = img.oriented(.right)
        case .rotate180: img = img.oriented(.down)
        case .rotate270: img = img.oriented(.left)
        }
        if img.extent.origin != .zero { img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y)) }
        let extent = img.extent

        if s.brightness != 0 || s.contrast != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: s.brightness / 50.0 * 0.5,
                kCIInputContrastKey: 1.0 + s.contrast / 50.0 * 0.75,
                kCIInputSaturationKey: 1.0])
        }
        if s.cb != 0 || s.cr != 0 {
            let m = chromaMatrix(kcb: 1 + s.cb / 50.0, kcr: 1 + s.cr / 50.0)
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
                "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
                "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        if s.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: s.sharpness / 50.0 * 1.5])
        } else if s.sharpness < 0 {
            img = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: -s.sharpness / 50.0 * 4.0]).cropped(to: extent)
        }
        if let ov = overlay {
            let placed = ov.transformed(by: CGAffineTransform(translationX: 8, y: extent.height - ov.extent.height - 8))
            img = placed.composited(over: img)
        }
        return img.cropped(to: extent)
    }

    /// RGB→YCbCr (BT.601), scale Cb/Cr independently, back to RGB — folded into one 3×3 matrix.
    private static func chromaMatrix(kcb: Double, kcr: Double) -> [[Double]] {
        let T: [[Double]] = [[0.299, 0.587, 0.114], [-0.168736, -0.331264, 0.5], [0.5, -0.418688, -0.081312]]
        let I: [[Double]] = [[1, 0, 1.402], [1, -0.344136, -0.714136], [1, 1.772, 0]]
        let D: [Double] = [1, kcb, kcr]
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { var s = 0.0; for k in 0..<3 { s += I[r][k] * D[k] * T[k][c] }; m[r][c] = s } }
        return m
    }

    // MARK: Overlay text

    private func overlay(for s: ProcessorSettings) -> CIImage? {
        guard !s.overlayText.isEmpty else { overlayImage = nil; overlayCacheKey = ""; return nil }
        let text = TokenFormatter.expand(s.overlayText)
        let key = "\(s.overlayFontSize)|\(text)"
        if key == overlayCacheKey, let img = overlayImage { return img }
        overlayCacheKey = key
        overlayImage = Self.renderOverlay(text: text, fontSize: CGFloat(s.overlayFontSize))
        return overlayImage
    }

    static func renderOverlay(text: String, fontSize: CGFloat) -> CIImage? {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -4.0]   // negative = fill and stroke
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        let pad = fontSize * 0.3
        let w = Int(ceil(bounds.width + pad * 2)), h = Int(ceil(bounds.height + pad * 2))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: Pixel buffer pool

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p; poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}

/// Small helper that renders CIImages into pooled BGRA pixel buffers of a fixed size
/// (used when writing stop-motion / continued-timelapse frames and when sizes must match).
final class PixelBufferRenderer {
    let size: CGSize
    private let processor = FrameProcessor()
    private var pool: CVPixelBufferPool?
    init(size: CGSize) { self.size = size }

    func render(_ image: CIImage) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let out = pb else { return nil }
        var img = image
        if img.extent.size != size {   // aspect-fit onto black
            let s = min(size.width / img.extent.width, size.height / img.extent.height)
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            img = img.transformed(by: CGAffineTransform(translationX: (size.width - img.extent.width) / 2 - img.extent.minX,
                                                        y: (size.height - img.extent.height) / 2 - img.extent.minY))
            img = img.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        }
        processor.ciContext.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }
}
