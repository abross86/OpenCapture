# OpenCapture

An open-source, native macOS video and audio capture app for USB capture cards, webcams and
other AVFoundation video sources. It is a from-scratch replacement for the abandoned
SwiftCapture (last updated 2023), keeping its workflow and feature set:

- **Live preview** with aspect-correct window, float-on-top, hidden title bar, full screen, mirror mode
- **Movie capture** to MP4/MOV — H.264, H.265, Motion JPEG, ProRes 422 LT/422/HQ; AAC or uncompressed audio;
  audio delay correction; time-limited recordings
- **Still images** — Save (⌘S), Copy (⌘C), or drag the frame out of the window; JPEG/PNG/TIFF at full/half/quarter size
- **Timelapse** — N frames every T seconds, played back at a chosen rate; continue an existing timelapse
- **Stop-motion** — frame-by-frame capture with frame averaging (noise reduction), onion skin, playback, multi-level undo,
  still-image export, and continuing an existing movie
- **Image adjustments** — brightness, contrast, Cb/Cr colour, sharpness; flip/rotate; text overlay with date/time tokens
- **Audio** — device/format/channel selection, level meters, monitoring through the Mac's speakers
- **AppleScript** — the same commands as SwiftCapture (`start capture`, `stop capture`, `save image`, `status`, …)
- **Hot-plug aware** — capture cards can be unplugged and reconnected without restarting the app

Requires macOS 14 or later. Apple silicon and Intel are both supported (the build targets the machine it runs on).

## Building

No Xcode project: the app is compiled with `swiftc` from the command-line tools.

```bash
./build.sh            # build into build/OpenCapture.app
./build.sh --run      # build and launch
./build.sh --install  # build and copy to /Applications
```

`build.sh` signs with a Developer ID certificate if one is installed, otherwise ad-hoc. A stable
signature matters: macOS ties the camera/microphone permission to the code signature, and an ad-hoc
signature changes with every build, so you may be asked for camera access again after rebuilding.

## Project layout

```
Sources/App         AppController (state machine + menu actions), MenuBuilder, main
Sources/Capture     CaptureEngine (AVCaptureSession, device/format selection, audio routing), DeviceManager, FrameProcessor
Sources/Preview     MetalPreviewView (Core Image → Metal)
Sources/Recording   MovieRecorder (AVAssetWriter), TimelapseSession, StopMotionSession, ImageCapture
Sources/UI          Video window, Stop-Motion window, Preferences (SwiftUI), Audio/Log panels
Sources/Scripting   AppleScript command classes (dictionary in Resources/OpenCapture.sdef)
Sources/Prefs       Preferences model (UserDefaults-backed)
```

### How frames flow

```
AVCaptureVideoDataOutput (BGRA)
   └─ FrameProcessor: transform → colour adjustments → text overlay   (pass-through when nothing is set)
        ├─ MetalPreviewView (live window)
        └─ FrameSinks: MovieRecorder / TimelapseSession / StopMotionSession
AVCaptureAudioDataOutput (float32)
   └─ AudioRemixer: pick left/right input channels → sinks + level meters
```

## AppleScript

```applescript
tell application "OpenCapture"
    set preferences video encoding h264_high audio encoding aac_high
    start capture to file "/Users/me/Desktop/clip.mp4"
    delay 10
    stop capture
    save image to file "/Users/me/Desktop/frame.jpg"
    set s to status
    videoWidth of s
end tell
```

Commands: `start capture`, `start timelapse capture`, `start stopmotion capture`, `capture stopmotion frame`,
`stop capture`, `save image`, `set preferences`, `video sources`, `audio sources`, `status`.
Open the dictionary in Script Editor (File › Open Dictionary) for every parameter.

## Troubleshooting

- The in-app log (Window › Log) is also written to `~/Library/Logs/OpenCapture.log`.
- No picture: check System Settings › Privacy & Security › Camera, then choose the device in Preferences.
  Capture cards appear with names such as "USB Video", "MS2109" or the brand name.
- Audio from a capture card is usually a separate "USB Audio" device; pick it under Audio source.
- 1080p60 cards offer MJPEG for 60 fps and raw YUV for lower rates; "Video input / format" lists both.

## License

MIT — see LICENSE.
