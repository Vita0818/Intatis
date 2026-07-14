import Foundation

/// `intatis` — the Swift-native CLI. Pure command-line Swift, so it builds and runs
/// from SwiftPM with no Xcode: `swift run intatis`.
@main
struct IntatisCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? ""
        do {
            switch command {
            case "", "chat", "code", "cowork":
                let config = try CLIConfig.load()
                let mode: Mode = command.isEmpty ? config.mode : (Mode(rawValue: command) ?? .chat)
                let pathArg = (command == "code" || command == "cowork") && args.count > 1
                    ? args[1] : FileManager.default.currentDirectoryPath
                try await runMode(config, mode: mode, workspace: URL(fileURLWithPath: pathArg).standardizedFileURL)
            case "settings":
                try runSettings()
            case "config":
                printConfig(try CLIConfig.load())
            case "selftest":
                try await runSelfTest()
            case "help", "--help", "-h":
                printHelp()
            default:
                errOut("unknown command: \(command)\n\n")
                printHelp()
                exit(2)
            }
        } catch {
            errOut("error: \(error.localizedDescription)\n")
            exit(1)
        }
    }
}
