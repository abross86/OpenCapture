-- Record a 10-second H.264 clip with AAC audio, then open it in QuickTime Player.
tell application "OpenCapture"
	set video encoding to h264_high
	set audio encoding to aac_high
	set moviePath to record movie to file (POSIX path of (path to desktop folder) & "clip.mp4") for 10
	-- "record movie ... for N" stops by itself; wait for the file to be finalised.
	repeat while recording
		delay 0.5
	end repeat
end tell
tell application "QuickTime Player" to open POSIX file moviePath
