// Intatis client-only patch: 2025-11-25 experimental Tasks wire surface.
//
// The upstream 0.12.1 source contains no Tasks types. These definitions mirror
// the frozen 2025-11-25 schema and do not implement or expose an MCP Server.

import Foundation

public let MCPRelatedTaskMetadataKey =
    "io.modelcontextprotocol/related-task"
public let MCPModelImmediateResponseMetadataKey =
    "io.modelcontextprotocol/model-immediate-response"

public enum MCPTaskStatus: String, Hashable, Codable, Sendable {
    case working
    case inputRequired = "input_required"
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .working, .inputRequired:
            return false
        }
    }
}

/// Metadata included under a request parameter's `task` field.
public struct MCPTaskMetadata: Hashable, Codable, Sendable {
    public let ttl: Int?

    public init(ttl: Int? = nil) {
        self.ttl = ttl
    }
}

public struct MCPRelatedTaskMetadata: Hashable, Codable, Sendable {
    public let taskId: String

    public init(taskId: String) {
        self.taskId = taskId
    }
}

/// Exact 2025-11-25 wire representation of a task.
public struct MCPTaskWire: Hashable, Codable, Sendable {
    public let taskId: String
    public let status: MCPTaskStatus
    public let statusMessage: String?
    public let createdAt: String
    public let lastUpdatedAt: String
    /// Required on the wire; `nil` encodes as JSON null for unlimited.
    public let ttl: Int?
    public let pollInterval: Int?

    public init(
        taskId: String,
        status: MCPTaskStatus,
        statusMessage: String? = nil,
        createdAt: String,
        lastUpdatedAt: String,
        ttl: Int?,
        pollInterval: Int? = nil
    ) {
        self.taskId = taskId
        self.status = status
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.ttl = ttl
        self.pollInterval = pollInterval
    }

    private enum CodingKeys: String, CodingKey {
        case taskId
        case status
        case statusMessage
        case createdAt
        case lastUpdatedAt
        case ttl
        case pollInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        status = try container.decode(MCPTaskStatus.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(
            String.self,
            forKey: .statusMessage)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastUpdatedAt = try container.decode(
            String.self,
            forKey: .lastUpdatedAt)
        guard container.contains(.ttl) else {
            throw DecodingError.keyNotFound(
                CodingKeys.ttl,
                .init(
                    codingPath: container.codingPath,
                    debugDescription:
                        "The 2025-11-25 Task.ttl field is required"))
        }
        ttl = try container.decodeIfPresent(Int.self, forKey: .ttl)
        pollInterval = try container.decodeIfPresent(
            Int.self,
            forKey: .pollInterval)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskId, forKey: .taskId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encode(ttl, forKey: .ttl)
        try container.encodeIfPresent(pollInterval, forKey: .pollInterval)
    }
}

public struct MCPCreateTaskResult: Hashable, Codable, Sendable {
    public let task: MCPTaskWire
    public var _meta: Metadata?

    public init(task: MCPTaskWire, _meta: Metadata? = nil) {
        self.task = task
        self._meta = _meta
    }
}

public enum GetTask: Method {
    public static let name = "tasks/get"

    public struct Parameters: Hashable, Codable, Sendable {
        public let taskId: String

        public init(taskId: String) {
            self.taskId = taskId
        }
    }

    public typealias Result = MCPTaskWire
}

public enum GetTaskPayload: Method {
    public static let name = "tasks/result"

    public struct Parameters: Hashable, Codable, Sendable {
        public let taskId: String

        public init(taskId: String) {
            self.taskId = taskId
        }
    }

    /// The result has the exact shape of the task's underlying request.
    public typealias Result = Value
}

public enum ListTasks: Method {
    public static let name = "tasks/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?

        public init() {
            cursor = nil
        }

        public init(cursor: String) {
            self.cursor = cursor
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public let tasks: [MCPTaskWire]
        public let nextCursor: String?
        public var _meta: Metadata?

        public init(
            tasks: [MCPTaskWire],
            nextCursor: String? = nil,
            _meta: Metadata? = nil
        ) {
            self.tasks = tasks
            self.nextCursor = nextCursor
            self._meta = _meta
        }
    }
}

public enum CancelTask: Method {
    public static let name = "tasks/cancel"

    public struct Parameters: Hashable, Codable, Sendable {
        public let taskId: String

        public init(taskId: String) {
            self.taskId = taskId
        }
    }

    public typealias Result = MCPTaskWire
}

public struct TaskStatusNotification: Notification {
    public static let name = "notifications/tasks/status"
    public typealias Parameters = MCPTaskWire
}

/// Empty object used by task capability leaves.
public struct MCPTaskCapability: Hashable, Codable, Sendable {
    public init() {}
}

public struct MCPServerTaskCapabilities: Hashable, Codable, Sendable {
    public struct Requests: Hashable, Codable, Sendable {
        public struct Tools: Hashable, Codable, Sendable {
            public var call: MCPTaskCapability?

            public init(call: MCPTaskCapability? = nil) {
                self.call = call
            }
        }

        public var tools: Tools?

        public init(tools: Tools? = nil) {
            self.tools = tools
        }
    }

    public var list: MCPTaskCapability?
    public var cancel: MCPTaskCapability?
    public var requests: Requests?

    public init(
        list: MCPTaskCapability? = nil,
        cancel: MCPTaskCapability? = nil,
        requests: Requests? = nil
    ) {
        self.list = list
        self.cancel = cancel
        self.requests = requests
    }
}

public struct MCPClientTaskCapabilities: Hashable, Codable, Sendable {
    public struct Requests: Hashable, Codable, Sendable {
        public struct Sampling: Hashable, Codable, Sendable {
            public var createMessage: MCPTaskCapability?

            public init(createMessage: MCPTaskCapability? = nil) {
                self.createMessage = createMessage
            }
        }

        public struct Elicitation: Hashable, Codable, Sendable {
            public var create: MCPTaskCapability?

            public init(create: MCPTaskCapability? = nil) {
                self.create = create
            }
        }

        public var sampling: Sampling?
        public var elicitation: Elicitation?

        public init(
            sampling: Sampling? = nil,
            elicitation: Elicitation? = nil
        ) {
            self.sampling = sampling
            self.elicitation = elicitation
        }
    }

    public var list: MCPTaskCapability?
    public var cancel: MCPTaskCapability?
    public var requests: Requests?

    public init(
        list: MCPTaskCapability? = nil,
        cancel: MCPTaskCapability? = nil,
        requests: Requests? = nil
    ) {
        self.list = list
        self.cancel = cancel
        self.requests = requests
    }
}

