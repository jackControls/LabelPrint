import Foundation

// One executable, two faces: with a command it is the `labelprint` command line tool,
// otherwise it is the Label Print app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, CLI.isCommand(first) {
    CLI.run(arguments)
} else if let first = arguments.first, !first.hasPrefix("-") {
    CLI.err("labelprint: Unknown command '\(first)'.\nRun 'labelprint help' for usage.")
    exit(2)
} else {
    LabelPrintApp.main()
}
