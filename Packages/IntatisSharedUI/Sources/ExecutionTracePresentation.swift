import Foundation
import IntatisConversation

/// Backend-only control for the verbose Code/Cowork execution transcript.
///
/// The EventLog and projections always retain the complete execution history.
/// This policy only decides which projected items reach the conversation UI.
public enum IntatisExecutionTracePresentation {
    public static let launchArgument = "-IntatisShowExecutionTrace"
    public static let environmentVariable = "INTATIS_SHOW_EXECUTION_TRACE"

    /// Defaults to `false`. This is intentionally not backed by UserDefaults or
    /// exposed through a settings control; changing it requires a new process.
    public static var isEnabled: Bool {
        resolve(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
    }

    public static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains(launchArgument) {
            return true
        }

        guard let rawValue = environment[environmentVariable] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }

    public static func displayedItems(_ items: [CodeItem]) -> [CodeItem] {
        displayedItems(items, showExecutionTrace: isEnabled)
    }

    public static func displayedItems(
        _ items: [CodeItem],
        showExecutionTrace: Bool
    ) -> [CodeItem] {
        guard !showExecutionTrace else { return items }
        return items.filter(\.isDefaultConversationPresentationItem)
    }
}
