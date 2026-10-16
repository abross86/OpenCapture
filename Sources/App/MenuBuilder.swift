import AppKit

enum MenuBuilder {
    static func build() -> NSMenu {
        let app = AppController.shared
        let main = NSMenu()

        // Application menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenCapture", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(AppController.openPreferences(_:)), keyEquivalent: ",").target = app
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(); NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OpenCapture", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenCapture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "OpenCapture"))

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save Image", action: #selector(AppController.saveImage(_:)), keyEquivalent: "s").target = app
        file.addItem(.separator())
        file.addItem(withTitle: "Start Recording…", action: #selector(AppController.startStopRecording(_:)), keyEquivalent: "r").target = app
        let limited = file.addItem(withTitle: "Start Time-Limited Recording…", action: #selector(AppController.startTimeLimitedRecording(_:)), keyEquivalent: "r")
        limited.keyEquivalentModifierMask = [.command, .option]; limited.target = app
        file.addItem(.separator())
        file.addItem(withTitle: "Start Timelapse Recording…", action: #selector(AppController.startStopTimelapse(_:)), keyEquivalent: "t").target = app
        file.addItem(withTitle: "Continue Timelapse Recording…", action: #selector(AppController.continueTimelapse(_:)), keyEquivalent: "").target = app
        file.addItem(.separator())
        let sm = file.addItem(withTitle: "Start Stop-Motion Recording…", action: #selector(AppController.startStopStopMotion(_:)), keyEquivalent: "m")
        sm.keyEquivalentModifierMask = [.command, .shift]; sm.target = app
        file.addItem(withTitle: "Continue Stop-Motion Recording…", action: #selector(AppController.continueStopMotion(_:)), keyEquivalent: "").target = app
        file.addItem(withTitle: "Export Stop-Motion Still Image Files…", action: #selector(AppController.exportStopMotionImages(_:)), keyEquivalent: "").target = app
        file.addItem(.separator())
        file.addItem(withTitle: "Show Capture Folder in Finder", action: #selector(AppController.revealCaptureFolder(_:)), keyEquivalent: "").target = app
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        // Video
        let video = NSMenu(title: "Video")
        video.addItem(withTitle: "Video Window - Float Over Other Applications", action: #selector(AppController.floatVideoWindow(_:)), keyEquivalent: "").target = app
        video.addItem(withTitle: "Video Window - Show Title Bar", action: #selector(AppController.toggleTitleBar(_:)), keyEquivalent: "").target = app
        video.addItem(withTitle: "Live Video - Flip Horizontally (Mirror)", action: #selector(AppController.toggleLiveFlip(_:)), keyEquivalent: "").target = app
        let fs = video.addItem(withTitle: "Enter Full Screen", action: #selector(AppController.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]; fs.target = app
        video.addItem(.separator())
        for (title, sel, key) in [("Move Window Up", #selector(AppController.windowUp(_:)), "\u{F700}"), ("Move Window Down", #selector(AppController.windowDown(_:)), "\u{F701}"),
                                  ("Move Window Left", #selector(AppController.windowLeft(_:)), "\u{F702}"), ("Move Window Right", #selector(AppController.windowRight(_:)), "\u{F703}")] {
            let i = video.addItem(withTitle: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = [.command, .option]; i.target = app
        }
        video.addItem(.separator())
        video.addItem(withTitle: "Stop-Motion: Add Frame  (Return)", action: #selector(AppController.addStopMotionFrame(_:)), keyEquivalent: "").target = app
        video.addItem(withTitle: "Stop-Motion: Onion Skin  (O)", action: #selector(AppController.toggleOnionSkin(_:)), keyEquivalent: "").target = app
        video.addItem(withTitle: "Stop-Motion: Play / Stop  (Space)", action: #selector(AppController.toggleStopMotionPlayback(_:)), keyEquivalent: "").target = app
        main.addItem(submenu(video, title: "Video"))

        // Audio
        let audio = NSMenu(title: "Audio")
        audio.addItem(withTitle: "Monitor Audio Through Speakers", action: #selector(AppController.toggleAudioMonitor(_:)), keyEquivalent: "").target = app
        audio.addItem(withTitle: "Audio Levels…", action: #selector(AppController.openAudioWindow(_:)), keyEquivalent: "").target = app
        main.addItem(submenu(audio, title: "Audio"))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Video", action: #selector(AppController.openVideoWindow(_:)), keyEquivalent: "1").target = app
        window.addItem(withTitle: "Audio", action: #selector(AppController.openAudioWindow(_:)), keyEquivalent: "2").target = app
        window.addItem(withTitle: "Log", action: #selector(AppController.openErrorsWindow(_:)), keyEquivalent: "3").target = app
        window.addItem(withTitle: "Stop-Motion", action: #selector(AppController.openStopMotionWindow(_:)), keyEquivalent: "4").target = app
        window.addItem(.separator())
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "OpenCapture User Manual", action: #selector(AppController.openUserManual(_:)), keyEquivalent: "?").target = app
        help.addItem(withTitle: "OpenCapture on GitHub", action: #selector(AppController.openProjectPage(_:)), keyEquivalent: "").target = app
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
