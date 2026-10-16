-- Build a stop-motion movie: one frame every time the user clicks "Capture".
tell application "OpenCapture"
	set stop motion averaging to 8 -- average 8 video frames per capture for a cleaner image
	set stop motion playback rate to 12
	start stop motion to file (POSIX path of (path to desktop folder) & "animation.mov")
	repeat
		set answer to button returned of (display dialog "Move the scene, then capture the next frame." buttons {"Finish", "Capture"} default button "Capture")
		if answer is "Finish" then exit repeat
		set n to add stop motion frame
	end repeat
	export stop motion frames to folder (POSIX path of (path to desktop folder) & "animation-frames")
	set moviePath to stop recording
end tell
