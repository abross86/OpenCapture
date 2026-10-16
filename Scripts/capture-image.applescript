-- Save the current video frame to the Desktop as PNG and show it in the Finder.
tell application "OpenCapture"
	if not video live then error "OpenCapture has no live video."
	set imagePath to capture image to file (POSIX path of (path to desktop folder) & "frame.png")
end tell
tell application "Finder" to reveal POSIX file imagePath
