import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Still-image capture from the live video: save to disk, copy to clipboard, drag out of the window.
enum ImageCapture {
    /// The current frame at the configured capture size (processing is already applied to live frames).
    static func currentImage(size: ImageCaptureSize) -> CGImage? {
        guard var img = CaptureEngine.shared.snapshotImage() else { return nil }
        if size.scale != 1 {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: size.scale, kCIInputAspectRatioKey: 1.0])
        }
        let extent = CGRect(x: 0, y: 0, width: img.extent.width.rounded(), height: img.extent.height.rounded())
        return FrameProcessorShared.context.createCGImage(img, from: extent)
    }

    static func encode(_ cg: CGImage, format: ImageFileFormat, quality: Double = 0.92) -> Data? {
        let type: UTType = [.jpeg, .png, .tiff][format.rawValue]
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        if format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1] }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Saves the current frame. With `url` nil the destination follows the preferences (ask / auto-name).
    @discardableResult
    static func save(to url: URL? = nil, format explicitFormat: ImageFileFormat? = nil) -> URL? {
        let p = Prefs.shared
        let format = explicitFormat ?? p.imageCaptureFormat
        guard let cg = currentImage(size: p.imageCaptureSize) else {
            ErrorLog.shared.log("Image", "No video frame available to save", code: 4001); return nil
        }
        var target = url
        if target == nil {
            if p.askWhereToSave {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [[UTType.jpeg, .png, .tiff][format.rawValue]]
                panel.nameFieldStringValue = TokenFormatter.expand(p.fileNameFormat)
                panel.directoryURL = p.captureDestinationURL
                guard panel.runModal() == .OK, let u = panel.url else { return nil }
                target = u
            } else {
                target = TokenFormatter.uniqueFileURL(in: p.captureDestinationURL, format: p.fileNameFormat, ext: format.fileExtension)
            }
        }
        guard let target, let data = encode(cg, format: format) else { return nil }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: target)
            if p.clickSound { playClick() }
            return target
        } catch {
            ErrorLog.shared.log("Image", "Could not save image: \(error.localizedDescription)", code: (error as NSError).code)
            return nil
        }
    }

    static func copyToPasteboard() {
        let p = Prefs.shared
        guard let cg = currentImage(size: p.imageCaptureSize), let data = encode(cg, format: p.imageCopyFormat) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: pasteboardType(for: p.imageCopyFormat))
        if p.clickSound { playClick() }
    }

    static func pasteboardType(for f: ImageFileFormat) -> NSPasteboard.PasteboardType {
        switch f { case .jpeg: return NSPasteboard.PasteboardType(UTType.jpeg.identifier); case .png: return .png; case .tiff: return .tiff }
    }

    static func playClick() {
        clickSound?.play()
    }
    private static let clickSound: NSSound? = {
        let s = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
        s?.volume = 0.6
        return s
    }()
}
