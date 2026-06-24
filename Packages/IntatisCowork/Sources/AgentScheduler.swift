import Foundation
import IntatisCore
import IntatisProtocol

public struct ScheduledTask: Codable, Sendable, Hashable {
    public var contract: TaskContract
    public var input: String
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var issuer: AgentID?
    public var assignee: AgentID
    public var causalParentID: TaskID?
    public var hopCount: Int
    public var visitedAgents: [AgentID]

    public init(contract: TaskContract,
                input: String,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                issuer: AgentID? = nil,
                assignee: AgentID,
                causalParentID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID]) {
        self.contract = contract
        self.input = input
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.issuer = issuer
        self.assignee = assignee
        self.causalParentID = causalParentID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
    }
}

public struct ExecutionRecord: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var assignee: AgentID
    public var status: TaskStatus
    public var result: String?
    public var error: String?
    public var rootTaskID: TaskID?
    public var parentTaskID: TaskID?
    public var hopCount: Int
    public var visitedAgents: [AgentID]

    public init(taskID: TaskID,
                assignee: AgentID,
                status: TaskStatus,
                result: String? = nil,
                error: String? = nil,
                rootTaskID: TaskID? = nil,
                parentTaskID: TaskID? = nil,
                hopCount: Int,
                visitedAgents: [AgentID]) {
        self.taskID = taskID
        self.assignee = assignee
        self.status = status
        self.result = result
        self.error = error
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.hopCount = hopCount
        self.visitedAgents = visitedAgents
    }
}

public struct AgentMailbox: Codable, Sendable, Hashable {
    public var pendingMessages: [MessageID]
    public var pendingTasks: [TaskID]
    public var completedResults: [ExecutionRecord]

    public init(pendingMessages: [MessageID] = [],
                pendingTasks: [TaskID] = [],
                completedResults: [ExecutionRecord] = []) {
        self.pendingMessages = pendingMessages
        self.pendingTasks = pendingTasks
        self.completedResults = completedResults
    }
}

public struct AgentScheduler: Sendable {
    private var queue: [ScheduledTask] = []
    private var records: [TaskID: ExecutionRecord] = [:]
    private var mailboxes: [AgentID: AgentMailbox] = [:]

    public init() {}

    @discardableResult
    public mutating func enqueue(_ task: ScheduledTask) -> TaskID {
        queue.append(task)
        records[task.contract.id] = ExecutionRecord(
            taskID: task.contract.id,
            assignee: task.assignee,
            status: .queued,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            hopCount: task.hopCount,
            visitedAgents: task.visitedAgents)
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.append(task.contract.id)
        return task.contract.id
    }

    public mutating func runNext() -> ScheduledTask? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    public mutating func runUntilIdle() -> [ScheduledTask] {
        var drained: [ScheduledTask] = []
        while let task = runNext() {
            drained.append(task)
        }
        return drained
    }

    public func awaitResult(taskID: TaskID) -> ExecutionRecord? {
        records[taskID]
    }

    public mutating func recordStarted(task: ScheduledTask) {
        var record = records[task.contract.id] ?? ExecutionRecord(
            taskID: task.contract.id,
            assignee: task.assignee,
            status: .queued,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            hopCount: task.hopCount,
            visitedAgents: task.visitedAgents)
        record.status = .running
        records[task.contract.id] = record
        mailboxes[task.assignee, default: AgentMailbox()].pendingTasks.removeAll { $0 == task.contract.id }
    }

    public mutating func recordCompleted(task: ScheduledTask, result: String) {
        let record = ExecutionRecord(
            taskID: task.contract.id,
            assignee: task.assignee,
            status: .completed,
            result: result,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            hopCount: task.hopCount,
            visitedAgents: task.visitedAgents)
        records[task.contract.id] = record
        mailboxes[task.assignee, default: AgentMailbox()].completedResults.append(record)
    }

    public mutating func recordFailed(task: ScheduledTask, error: String) {
        let record = ExecutionRecord(
            taskID: task.contract.id,
            assignee: task.assignee,
            status: .failed,
            error: error,
            rootTaskID: task.rootTaskID,
            parentTaskID: task.parentTaskID,
            hopCount: task.hopCount,
            visitedAgents: task.visitedAgents)
        records[task.contract.id] = record
        mailboxes[task.assignee, default: AgentMailbox()].completedResults.append(record)
    }

    public func queuedTasks() -> [ScheduledTask] {
        queue
    }

    public func mailbox(for agent: AgentID) -> AgentMailbox {
        mailboxes[agent] ?? AgentMailbox()
    }

    public func record(for taskID: TaskID) -> ExecutionRecord? {
        records[taskID]
    }
}
