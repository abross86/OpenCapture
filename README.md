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

OpenCapture is fully scriptable. Every preference is a read/write property of the application,
live state is readable, and the capture verbs return the file they created. Open the dictionary in
Script Editor (File › Open Dictionary › OpenCapture) for the complete list; ready-made examples are
in `Scripts/`.

```applescript
tell application "OpenCapture"
    -- live state
    video device name            -- "USB Video"
    video width & video height   -- 1920, 1080
    frame rate                   -- 59.94
    video formats                -- {"1920 × 1080  MJPEG  60 fps", "1280 × 720  YUV 4:2:2  30 fps", …}

    -- preferences are properties
    set video source to "USB Video"
    set video format to "1920 × 1080  MJPEG  60 fps"
    set audio source to "USB Audio"
    set video encoding to h264_high
    set brightness to 5
    set text overlay to "+Y-+M-+D +h:+m:+s"

    -- capture verbs return the path they wrote
    set img to capture image to file "/Users/me/Desktop/frame.png"
    set clip to record movie to file "/Users/me/Desktop/clip.mp4" for 10
    repeat while recording
        delay 0.5
    end repeat

    start timelapse to file "/Users/me/Desktop/tl.mp4"
    delay 600
    stop recording

    start stop motion to file "/Users/me/Desktop/anim.mov"
    add stop motion frame
    add stop motion frame
    export stop motion frames to folder "/Users/me/Desktop/anim-frames"
    stop recording
end tell
```

Verbs: `record movie` (`to file`, `for` seconds), `stop recording`, `capture image` (`to file`, `in format`),
`copy image`, `start timelapse`, `start stop motion` (both take `to file` / `continuing`), `add stop motion frame`,
`export stop motion frames to folder`, `reset image adjustments`, `refresh devices`.

The SwiftCapture command names (`start capture`, `stop capture`, `save image`, `status`,
`set preferences`, `video sources`, `audio sources`, …) are kept in a compatibility suite, so
existing scripts only need `tell application "OpenCapture"`.

From the shell:

```bash
osascript -e 'tell application "OpenCapture" to capture image to file "/tmp/frame.jpg"'
```

## Troubleshooting

- The in-app log (Window › Log) is also written to `~/Library/Logs/OpenCapture.log`.
- No picture: check System Settings › Privacy & Security › Camera, then choose the device in Preferences.
  Capture cards appear with names such as "USB Video", "MS2109" or the brand name.
- Audio from a capture card is usually a separate "USB Audio" device; pick it under Audio source.
- 1080p60 cards offer MJPEG for 60 fps and raw YUV for lower rates; "Video input / format" lists both.

## License

MIT — see LICENSE.
