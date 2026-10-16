-- Pick the capture device and its stream format from lists, then report what is live.
tell application "OpenCapture"
	set chosen to choose from list (video sources) with prompt "Video source:"
	if chosen is false then return
	set video source to item 1 of chosen
	delay 1
	set fmt to choose from list (video formats) with prompt "Stream format:" default items {video format}
	if fmt is not false then set video format to item 1 of fmt
	delay 2
	display dialog video device name & ": " & video width & " × " & video height & " at " & (round (get frame rate)) & " fps"
end tell
