import AppKit

if CommandLine.arguments.dropFirst().first == "mcp" {
    exit(MCPServer.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = InklineApplication()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = delegate.makeMenu()
app.run()
