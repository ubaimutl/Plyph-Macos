import AppKit

print("[Plyph] main.swift starting")
NSLog("[Plyph] main.swift starting")

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
