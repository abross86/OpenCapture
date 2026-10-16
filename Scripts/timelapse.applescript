-- One frame every 5 seconds for an hour, played back at 30 fps (a 12-second movie).
tell application "OpenCapture"
	set timelapse frames to 1
	set timelapse interval to 5
	set timelapse playback rate to 30
	set text overlay to "+Y-+M-+D +h:+m"
	start timelapse to file (POSIX path of (path to desktop folder) & "timelapse.mp4")
	delay 3600
	set finished to stop recording
	set text overlay to ""
end tell
display notification finished with title "Timelapse finished"
