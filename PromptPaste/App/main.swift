import AppKit

print("[PromptPaste] main.swift starting")
NSLog("[PromptPaste] main.swift starting")

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
