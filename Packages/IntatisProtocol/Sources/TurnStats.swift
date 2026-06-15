import Foundation

/// Per-turn statistics emitted after the model finishes a reply: token usage
/// (when the endpoint reports it), time-to-first-token, and total wall time.
/// `promptTokens` doubles as the context-window occupancy for the turn.
public struct TurnStatsPayload: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var ttftMillis: Int?
    public var totalMillis: Int?
    public var model: String?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
                ttftMillis: Int? = nil, totalMillis: Int? = nil, model: String? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.ttftMillis = ttftMillis
        self.totalMillis = totalMillis
        self.model = model
    }
}
