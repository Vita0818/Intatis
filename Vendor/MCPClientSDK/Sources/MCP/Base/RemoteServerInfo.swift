/// Implementation information reported by the remote MCP server during
/// initialization. This is wire metadata, not an MCP server implementation.
public struct RemoteServerInfo: Hashable, Codable, Sendable {
    public let name: String
    public let title: String?
    public let version: String
    public let description: String?
    public let websiteUrl: String?
    public let icons: [Icon]?

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil,
        websiteUrl: String? = nil,
        icons: [Icon]? = nil
    ) {
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.websiteUrl = websiteUrl
        self.icons = icons
    }
}

/// Capabilities reported by the remote MCP server. This type contains only
/// negotiated wire values and cannot host or handle MCP requests.
///
/// Intatis adds the 2025-11-25 experimental Tasks capability shape because it
/// is absent from the pinned upstream 0.12.1 source.
public struct RemoteServerCapabilities: Hashable, Codable, Sendable {
    public struct Resources: Hashable, Codable, Sendable {
        public var subscribe: Bool?
        public var listChanged: Bool?

        public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
            self.subscribe = subscribe
            self.listChanged = listChanged
        }
    }

    public struct Tools: Hashable, Codable, Sendable {
        public var listChanged: Bool?

        public init(listChanged: Bool? = nil) {
            self.listChanged = listChanged
        }
    }

    public struct Prompts: Hashable, Codable, Sendable {
        public var listChanged: Bool?

        public init(listChanged: Bool? = nil) {
            self.listChanged = listChanged
        }
    }

    public struct Logging: Hashable, Codable, Sendable {
        public init() {}
    }

    public struct Completions: Hashable, Codable, Sendable {
        public init() {}
    }

    public var completions: Completions?
    public var logging: Logging?
    public var prompts: Prompts?
    public var resources: Resources?
    public var tools: Tools?
    public var tasks: MCPServerTaskCapabilities?

    public init(
        completions: Completions? = nil,
        logging: Logging? = nil,
        prompts: Prompts? = nil,
        resources: Resources? = nil,
        tools: Tools? = nil,
        tasks: MCPServerTaskCapabilities? = nil
    ) {
        self.completions = completions
        self.logging = logging
        self.prompts = prompts
        self.resources = resources
        self.tools = tools
        self.tasks = tasks
    }
}
