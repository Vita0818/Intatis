import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisPermission

private func ctx(profile: PermissionProfile = .reviewed,
                 allowsShell: Bool = true,
                 root: String = "/ws") -> PermissionContext {
    PermissionContext(workspaceRoot: URL(fileURLWithPath: root), profile: profile, allowsShell: allowsShell)
}

private func call(_ name: String, _ side: SideEffect,
                  paths: [String] = [], network: Bool = false, args: String = "{}") -> ToolCallContext {
    ToolCallContext(toolName: name, sideEffect: side, touchedPaths: paths, risksNetwork: network, rawArgs: args)
}

final class IntatisPermissionTests: XCTestCase {

    private let gate = DeterministicPolicyGate()

    // MARK: Scanners

    func testSecretScannerPaths() {
        XCTAssertTrue(SecretScanner.isSensitivePath(".env"))
        XCTAssertTrue(SecretScanner.isSensitivePath("config/.env.local"))
        XCTAssertTrue(SecretScanner.isSensitivePath("home/.ssh/id_rsa"))
        XCTAssertTrue(SecretScanner.isSensitivePath("certs/server.pem"))
        XCTAssertFalse(SecretScanner.isSensitivePath("src/main.swift"))
    }

    func testProtectedConfig() {
        XCTAssertTrue(SecretScanner.isProtectedConfigPath("package-lock.json"))
        XCTAssertTrue(SecretScanner.isProtectedConfigPath(".github/workflows/ci.yml"))
        XCTAssertFalse(SecretScanner.isProtectedConfigPath("src/a.swift"))
    }

    func testContainsSecret() {
        XCTAssertTrue(SecretScanner.containsSecret("token=ghp_abcdef123456"))
        XCTAssertTrue(SecretScanner.containsSecret("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertFalse(SecretScanner.containsSecret("just some normal source code"))
    }

    func testShellInspector() {
        XCTAssertTrue(ShellInspector.isDangerous("sudo rm -rf /"))
        XCTAssertTrue(ShellInspector.risksNetworkOrInstall("npm install left-pad"))
        XCTAssertTrue(ShellInspector.isReadOnlyCommand("ls -la"))
        XCTAssertFalse(ShellInspector.isReadOnlyCommand("rm file"))
    }

    // MARK: Gate

    func testGateReadAllow() {
        guard case .allow = gate.evaluate(call("read_file", .readOnly, paths: ["a.swift"]), ctx()) else {
            return XCTFail("read should allow")
        }
    }

    func testGateWriteReviewedPasses() {
        guard case .pass = gate.evaluate(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .reviewed)) else {
            return XCTFail("write in reviewed should pass to reviewer")
        }
    }

    func testGateWriteManualAsks() {
        guard case .ask = gate.evaluate(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .manual)) else {
            return XCTFail("write in manual should ask")
        }
    }

    func testGateDeniesSensitiveRead() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: [".env"]), ctx()) else {
            return XCTFail(".env read should deny")
        }
    }

    func testGateDeniesEscape() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: ["../etc/passwd"]), ctx()) else {
            return XCTFail("escape should deny")
        }
    }

    func testGateShellDeniedInSandbox() {
        guard case .deny = gate.evaluate(call("run_shell", .exec, args: #"{"command":"ls"}"#),
                                         ctx(allowsShell: false)) else {
            return XCTFail("shell with allowsShell=false should deny")
        }
    }

    func testGateShellSudoDenied() {
        guard case .deny = gate.evaluate(call("run_shell", .exec, args: #"{"command":"sudo rm -rf /"}"#),
                                         ctx(allowsShell: true)) else {
            return XCTFail("sudo should deny")
        }
    }

    func testGateShellReadOnlyAllowed() {
        guard case .allow = gate.evaluate(call("run_shell", .exec, args: #"{"command":"ls -la"}"#),
                                          ctx(profile: .reviewed, allowsShell: true)) else {
            return XCTFail("ls should allow")
        }
    }

    func testGateLockedDenies() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: ["a"]), ctx(profile: .locked)) else {
            return XCTFail("locked should deny")
        }
    }

    // MARK: Engine

    func testEnginePassWithoutReviewerAsks() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .reviewed))
        XCTAssertEqual(outcome.decision, .askUser)
    }

    func testEngineDenyIsFinal() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("read_file", .readOnly, paths: [".env"]), ctx())
        XCTAssertEqual(outcome.decision, .deny)
    }

    func testEngineAllowPassesThrough() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("read_file", .readOnly, paths: ["a.swift"]), ctx())
        XCTAssertEqual(outcome.decision, .allow)
    }

    func testEngineReviewerHandlesPass() async {
        struct AllowReviewer: PermissionReviewer {
            func review(_ c: ToolCallContext, _ x: PermissionContext,
                        gateReason: String, risk: RiskLevel) async -> PermissionOutcome {
                PermissionOutcome(decision: .allow, risk: .low, reason: "reviewer ok")
            }
        }
        let engine = PermissionEngine(reviewer: AllowReviewer())
        let outcome = await engine.decide(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .reviewed))
        XCTAssertEqual(outcome.decision, .allow)
        XCTAssertEqual(outcome.reason, "reviewer ok")
    }
}
