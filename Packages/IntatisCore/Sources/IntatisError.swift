import Foundation

/// Unified error type across all Intatis modules.
public enum IntatisError: Error, Sendable, Equatable, LocalizedError {
    case config(String)
    case provider(String)
    case decoding(String)
    case io(String)
    case notFound(String)
    case permissionDenied(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .config(let m):           return "Configuration error: \(m)"
        case .provider(let m):         return "Provider error: \(m)"
        case .decoding(let m):         return "Decoding error: \(m)"
        case .io(let m):               return "I/O error: \(m)"
        case .notFound(let m):         return "Not found: \(m)"
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .cancelled:               return "Cancelled."
        }
    }
}
