import SwiftUI
import AVFoundation

struct PreferencesView: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var devices = DeviceManager.shared
    @State private var showNameHelp = false
    @State private var showOverlayHelp = false

    private var selectedVideoDevice: AVCaptureDevice? { devices.videoDevice(preferredID: prefs.videoDeviceID) }
    private var formats: [AVCaptureDevice.Format] {
        selectedVideoDevice?.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video } ?? []
    }

    var body: some View {
        Form {
            Section("Video") {
                Picker("Video source:", selection: $prefs.videoDeviceID) {
                    Text("Automatic (first available)").tag("")
                    ForEach(devices.videoDevices, id: \.uniqueID) { d in Text(d.localizedName).tag(d.uniqueID) }
                }
                Picker("Video input / format:", selection: $prefs.videoFormatKey) {
                    Text("Automatic (best match for size and frame rate)").tag("")
                    ForEach(formats, id: \.self) { f in Text(DeviceManager.formatLabel(f)).tag(DeviceManager.formatKey(f)) }
                }
                LabeledContent("Video size:") {
                    HStack(spacing: 6) {
                        IntField(value: $prefs.videoWidth, placeholder: "max").frame(width: 64)
                        Text("×")
                        IntField(value: $prefs.videoHeight, placeholder: "max").frame(width: 64)
                        Menu {
                            Button("Maximum supported") { prefs.videoWidth = 0; prefs.videoHeight = 0 }
                            Section("16:9") {
                                ForEach(Self.presets16x9, id: \.0) { p in Button(p.2) { prefs.videoWidth = p.0; prefs.videoHeight = p.1 } }
                            }
                            Section("4:3") {
                                ForEach(Self.presets4x3, id: \.0) { p in Button(p.2) { prefs.videoWidth = p.0; prefs.videoHeight = p.1 } }
                            }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize()
                        Text("leave empty for maximum").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Video frame rate:") {
                    HStack { DoubleField(value: $prefs.videoFrameRate, placeholder: "max").frame(width: 64); Text("frames per second") }
                }
                Picker("Video buffer size:", selection: $prefs.videoBufferSize) { ForEach(VideoBufferSize.allCases) { Text($0.label).tag($0) } }
                Picker("Video transformation:", selection: $prefs.videoTransform) { ForEach(VideoTransform.allCases) { Text($0.label).tag($0) } }
                Toggle("Live video horizontal flip (capture unaffected)", isOn: $prefs.liveFlipHorizontal)
            }

            Section("Audio") {
                Picker("Audio source:", selection: $prefs.audioDeviceID) {
                    Text("Automatic (first available)").tag("")
                    Text("No audio input").tag("none")
                    ForEach(devices.audioDevices, id: \.uniqueID) { d in Text(d.localizedName).tag(d.uniqueID) }
                }
                Picker("Audio format:", selection: $prefs.audioFormat) { ForEach(AudioFormat.allCases) { Text($0.label).tag($0) } }
                LabeledContent("Audio left/mono channel:") {
                    HStack {
                        Picker("", selection: $prefs.audioLeftChannel) { ForEach(1...16, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 70)
                        Text("Right channel:").padding(.leading, 12)
                        Picker("", selection: $prefs.audioRightChannel) { ForEach(1...16, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 70)
                            .disabled(!prefs.audioFormat.isStereo)
                    }
                }
                LabeledContent("Audio delay for movies:") {
                    HStack { IntField(value: $prefs.audioDelayMs, placeholder: "0", allowNegative: true).frame(width: 64); Text("milliseconds (positive = audio later)") }
                }
            }

            Section("Image adjustments") {
                AdjustmentRow(label: "Brightness:", value: $prefs.brightness)
                AdjustmentRow(label: "Contrast:", value: $prefs.contrast)
                AdjustmentRow(label: "Cb colour adjustment:", value: $prefs.cbAdjust)
                AdjustmentRow(label: "Cr colour adjustment:", value: $prefs.crAdjust)
                AdjustmentRow(label: "Sharpness:", value: $prefs.sharpness)
            }

            Section("Files") {
                LabeledContent("File name format:") {
                    HStack {
                        TextField("", text: $prefs.fileNameFormat)
                        Button { showNameHelp.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless)
                            .popover(isPresented: $showNameHelp) { TokenHelp(what: "file names").padding() }
                    }
                }
                LabeledContent("Capture destination:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $prefs.askWhereToSave) {
                            Text("Ask each time").tag(true)
                            Text("Save automatically to:").tag(false)
                        }.pickerStyle(.radioGroup).labelsHidden()
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text((prefs.captureDestination as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseFolder() }
                        }.disabled(prefs.askWhereToSave)
                    }
                }
                Picker("Image capture size:", selection: $prefs.imageCaptureSize) { ForEach(ImageCaptureSize.allCases) { Text($0.label).tag($0) } }
                Picker("Image capture format:", selection: $prefs.imageCaptureFormat) { ForEach(ImageFileFormat.allCases) { Text($0.label).tag($0) } }
                Picker("Image copy/drag format:", selection: $prefs.imageCopyFormat) { ForEach(ImageFileFormat.allCases) { Text($0.label).tag($0) } }
                Toggle("Play click sound upon image capture", isOn: $prefs.clickSound)
            }

            Section("Text overlay") {
                LabeledContent("Text overlay:") {
                    HStack {
                        TextField("", text: $prefs.overlayText, prompt: Text("e.g. +Y-+M-+D +h:+m:+s"))
                        Button { showOverlayHelp.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless)
                            .popover(isPresented: $showOverlayHelp) { TokenHelp(what: "the overlay").padding() }
                    }
                }
                LabeledContent("Text overlay font size:") { IntField(value: $prefs.overlayFontSize, placeholder: "16").frame(width: 64) }
            }

            Section("Timelapse") {
                LabeledContent("Timelapse capture rate:") {
                    HStack {
                        IntField(value: $prefs.timelapseFrames, placeholder: "1").frame(width: 56); Text("frames, every")
                        DoubleField(value: $prefs.timelapseInterval, placeholder: "10").frame(width: 64); Text("seconds")
                    }
                }
                LabeledContent("Timelapse playback rate:") {
                    HStack { DoubleField(value: $prefs.timelapsePlaybackFPS, placeholder: "30").frame(width: 64); Text("frames per second") }
                }
            }

            Section("Stop-motion") {
                LabeledContent("Stop-motion frame averaging:") {
                    HStack { IntField(value: $prefs.stopMotionAveraging, placeholder: "1").frame(width: 56); Text("frames per capture (noise reduction)") }
                }
                LabeledContent("Stop-motion playback rate:") {
                    HStack { DoubleField(value: $prefs.stopMotionPlaybackFPS, placeholder: "30").frame(width: 64); Text("frames per second") }
                }
            }

            Section("Movie encoding") {
                Picker("Video encoding for movies:", selection: $prefs.videoEncoding) { ForEach(VideoEncoding.allCases) { Text($0.label).tag($0) } }
                Picker("Audio encoding for movies:", selection: $prefs.audioEncoding) { ForEach(AudioEncoding.allCases) { Text($0.label).tag($0) } }
                Text(prefs.videoEncoding.isTemporallyCompressed && prefs.audioEncoding.isAAC
                     ? "Movies are saved as MP4. Stop-motion movies use JPEG frames (in a MOV) so they can be edited frame by frame."
                     : "Movies are saved as QuickTime (MOV).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Video window") {
                Picker("Video window button:", selection: $prefs.titleBarButton) { ForEach(TitleBarButton.allCases) { Text($0.label).tag($0) } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 760)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = prefs.captureDestinationURL
        if panel.runModal() == .OK, let u = panel.url { prefs.captureDestination = u.path }
    }

    static let presets16x9: [(Int, Int, String)] = [
        (640, 360, "640 × 360 (half 720p)"), (960, 540, "960 × 540 (half 1080p)"), (1280, 720, "1280 × 720 (720p)"),
        (1920, 1080, "1920 × 1080 (1080p)"), (2560, 1440, "2560 × 1440 (QHD)"), (3840, 2160, "3840 × 2160 (4K)")]
    static let presets4x3: [(Int, Int, String)] = [
        (320, 240, "320 × 240"), (640, 480, "640 × 480"), (800, 600, "800 × 600"), (1024, 768, "1024 × 768"), (1600, 1200, "1600 × 1200")]
}

struct AdjustmentRow: View {
    let label: String
    @Binding var value: Double
    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: -50...50, step: 1)
                Text("\(Int(value))").monospacedDigit().frame(width: 32, alignment: .trailing)
                Button("Reset") { value = 0 }.controlSize(.small).disabled(value == 0)
            }
        }
    }
}

struct TokenHelp: View {
    let what: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In \(what), use + followed by a letter to insert the date or time:").font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text("+Y").monospaced(); Text("Year (four digits)") }
                GridRow { Text("+y").monospaced(); Text("Year (two digits)") }
                GridRow { Text("+M").monospaced(); Text("Month (two digits)") }
                GridRow { Text("+D").monospaced(); Text("Day (two digits)") }
                GridRow { Text("+h").monospaced(); Text("Hour (two digits)") }
                GridRow { Text("+m").monospaced(); Text("Minute (two digits)") }
                GridRow { Text("+s").monospaced(); Text("Second (two digits)") }
            }.font(.callout)
            Text("Example: +Y-+M-+D +h-+m-+s → \(TokenFormatter.expand("+Y-+M-+D +h-+m-+s"))").font(.caption).foregroundStyle(.secondary)
            if what == "file names" { Text("The file extension is added automatically.").font(.caption).foregroundStyle(.secondary) }
        }.frame(width: 300)
    }
}

/// Text field bound to an Int where empty means 0.
struct IntField: View {
    @Binding var value: Int
    var placeholder: String
    var allowNegative = false
    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value == 0 ? "" : String(value) },
            set: { s in
                let filtered = s.filter { $0.isNumber || (allowNegative && $0 == "-") }
                value = Int(filtered) ?? 0
            }))
        .multilineTextAlignment(.trailing)
    }
}

/// Text field bound to a Double where empty means 0.
struct DoubleField: View {
    @Binding var value: Double
    var placeholder: String
    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value == 0 ? "" : String(format: "%g", value) },
            set: { s in value = Double(s.filter { $0.isNumber || $0 == "." }) ?? 0 }))
        .multilineTextAlignment(.trailing)
    }
}
