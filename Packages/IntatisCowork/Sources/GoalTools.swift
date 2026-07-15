import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

private func encodeGoalToolResult<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

public struct CreateGoalTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "create_goal",
        description: "Create the session's durable Goal only when the user or host explicitly requested Goal mode. Never infer a Goal from an ordinary task. Optional token_budget is accepted only when explicitly supplied.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "objective": .object(["type": .string("string"), "minLength": .number(1)]),
                "success_criteria": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string"), "minLength": .number(1)]),
                ]),
                "constraints": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string"), "minLength": .number(1)]),
                ]),
                "token_budget": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                ]),
            ]),
            "required": .array([.string("objective")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var objective: String
        var successCriteria: [String]?
        var constraints: [String]?
        var tokenBudget: Int?

        enum CodingKeys: String, CodingKey {
            case objective, constraints
            case successCriteria = "success_criteria"
            case tokenBudget = "token_budget"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "goal.create",
            resources: [PermissionResource(kind: .goal, value: "current")],
            metadata: [
                "objectiveLength": .number(Double(value?.objective.count ?? 0)),
                "hasTokenBudget": .bool(value?.tokenBudget != nil),
            ],
            dataEffects: [.none],
            controlEffects: [.createGoal],
            risks: [.controlPlaneMutation, .modelCost],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.goalManager else {
            return ToolObservation(text: "Goal management is not available in this session")
        }
        let goal = try await manager.createGoal(GoalCreateRequest(
            objective: value.objective,
            successCriteria: value.successCriteria ?? [],
            constraints: value.constraints ?? [],
            tokenBudget: value.tokenBudget))
        struct Response: Encodable { var goal: Goal }
        return ToolObservation(text: try encodeGoalToolResult(Response(goal: goal)))
    }
}

public struct GetGoalTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "get_goal",
        description: "Read the authoritative current durable Goal, including status, revision, explicit budget/usage, elapsed time, and latest audit. Returns null when no Goal exists.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
            "additionalProperties": .bool(false),
        ]))

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        PermissionIntent(
            action: "goal.get",
            resources: [PermissionResource(kind: .goal, value: "current")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        guard let manager = context.goalManager else {
            return ToolObservation(text: "Goal management is not available in this session")
        }
        struct Response: Encodable { var goal: Goal? }
        return ToolObservation(text: try encodeGoalToolResult(
            Response(goal: await manager.currentGoal())))
    }
}

public struct UpdateGoalTool: Tool {
    public init() {}

    public static let descriptor = ToolDescriptor(
        name: "update_goal",
        description: "Submit only a complete or blocked Goal status candidate using the current revision. Host authority and completion audit requirements remain final. This tool is reserved for a Goal verifier capability; it cannot pause, resume, edit, clear, or change budgets.",
        sideEffect: .write,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "goal_id": .object(["type": .string("string"), "minLength": .number(1)]),
                "expected_revision": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                ]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("complete"), .string("blocked")]),
                ]),
            ]),
            "required": .array([.string("expected_revision"), .string("status")]),
            "additionalProperties": .bool(false),
        ]))

    private struct Args: Decodable {
        var goalID: String?
        var expectedRevision: Int
        var status: String

        enum CodingKeys: String, CodingKey {
            case status
            case goalID = "goal_id"
            case expectedRevision = "expected_revision"
        }
    }

    public func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        let value = try? args.decode(Args.self)
        return PermissionIntent(
            action: "goal.submit_verdict",
            resources: [PermissionResource(kind: .goal, value: value?.goalID ?? "current")],
            metadata: ["status": value.map { .string($0.status) } ?? .null],
            dataEffects: [.none],
            controlEffects: [.submitGoalVerdict],
            risks: [.controlPlaneMutation],
            replayPolicy: .requiresManualReconciliation)
    }

    public func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation {
        let value = try args.decode(Args.self)
        guard let manager = context.goalManager else {
            return ToolObservation(text: "Goal management is not available in this session")
        }
        let goalID: GoalID
        if let raw = value.goalID {
            goalID = GoalID(rawValue: raw)
        } else if let current = try await manager.currentGoal() {
            goalID = current.id
        } else {
            throw IntatisError.notFound("no current Goal exists")
        }
        let status: GoalStatus = value.status == "complete" ? .completed : .blocked
        let goal = try await manager.transitionGoal(
            goalID,
            expectedRevision: value.expectedRevision,
            to: status)
        struct Response: Encodable { var goal: Goal }
        return ToolObservation(text: try encodeGoalToolResult(Response(goal: goal)))
    }
}
