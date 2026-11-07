import AppKit

let arguments = CommandLine.arguments

// `Perch --mcp` is what AI clients launch: a pipe to the running app, with no UI of its own.
if arguments.contains("--mcp") {
    MCPProxy.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
