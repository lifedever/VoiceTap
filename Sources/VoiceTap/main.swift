import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 纯状态栏程序，不要 Dock 图标
app.setActivationPolicy(.accessory)
app.run()
