-- Print the capture state (handy from the shell: osascript Scripts/status.applescript)
tell application "OpenCapture"
	set out to "video: " & video device name & " " & video width & "x" & video height & " @ " & (round (get frame rate)) & " fps" & linefeed
	set out to out & "audio: " & audio device name & linefeed
	set out to out & "mode:  " & (capture mode as text)
	if recording then set out to out & "  " & (round (get recording duration)) & " s  " & recording file
	return out
end tell
