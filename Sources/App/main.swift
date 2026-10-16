import AppKit

let app = NSApplication.shared
let controller = AppController.shared
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
