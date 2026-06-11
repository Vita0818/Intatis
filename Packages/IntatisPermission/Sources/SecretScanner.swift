import Foundation

/// Deterministic detection of sensitive files, secret-bearing content, and
/// protected config — the hard rules that must never depend on a model
/// (ARCHITECTURE.md §6.2, §6.5).
public enum SecretScanner {

    private static let sensitiveBasenames: Set<String> = [
        ".env", ".netrc", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "credentials", ".npmrc", ".pypirc",
    ]
    private static let sensitiveExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "asc",
    ]
    private static let sensitiveDirHints: [String] = [
        "/.ssh/", "/.aws/", "/.gnupg/", "/.gpg/", "secrets/", "/.config/gh/",
    ]

    /// A path that must never be read or written by a tool.
    public static func isSensitivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        if sensitiveBasenames.contains(base) { return true }
        if base.hasPrefix(".env") { return true }                 // .env, .env.local, .env.production
        if let ext = base.split(separator: ".").last.map(String.init),
           base.contains("."), sensitiveExtensions.contains(ext) { return true }
        let padded = "/" + lower
        for hint in sensitiveDirHints where padded.contains(hint) { return true }
        return false
    }

    /// Content that looks like it carries a secret (used for shell + agent-to-agent forwarding).
    public static func containsSecret(_ text: String) -> Bool {
        let markers = [
            "-----BEGIN", "PRIVATE KEY", "AKIA", "ASIA", "sk-", "ssh-rsa ",
            "xoxb-", "xoxp-", "ghp_", "github_pat_", "AIza",
        ]
        return markers.contains { text.contains($0) }
    }

    private static let protectedBasenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock",
        "podfile.lock", "gemfile.lock", "package.resolved", "poetry.lock",
    ]
    private static let protectedHints: [String] = [
        ".github/workflows/", ".gitlab-ci", "/dockerfile", "/makefile",
        ".circleci/", "fastlane/", "/ci/",
    ]

    /// Lockfiles / CI / build config: edits must go to the user even in autopilot.
    public static func isProtectedConfigPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        if protectedBasenames.contains(base) { return true }
        let padded = "/" + lower
        for hint in protectedHints where padded.contains(hint) { return true }
        return false
    }
}

/// Heuristics for `run_shell` command strings.
public enum ShellInspector {

    private static let dangerous: [String] = [
        "sudo", "rm -rf", "rm -fr", "rm -r ", ":(){", "mkfs", "dd if=", "> /dev/sd",
        "chmod -r 777", "chown -r", "/etc/", "~/.ssh", "shutdown", "reboot", "killall",
    ]
    private static let networkOrInstall: [String] = [
        "curl ", "wget ", "npm install", "npm i ", "yarn add", "pnpm add", "pip install",
        "pip3 install", "apt ", "apt-get", "brew install", "gem install", "git clone",
        "git push", "git pull", "git fetch", "nc ", "ssh ", "scp ",
    ]
    private static let readOnlyAllowlist: Set<String> = [
        "ls", "pwd", "cat", "grep", "rg", "echo", "head", "tail", "wc", "find", "true",
    ]

    public static func isDangerous(_ command: String) -> Bool {
        let lower = command.lowercased()
        return dangerous.contains { lower.contains($0) }
    }

    public static func risksNetworkOrInstall(_ command: String) -> Bool {
        let lower = command.lowercased()
        return networkOrInstall.contains { lower.contains($0) }
    }

    public static func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.split(separator: " ").first.map(String.init) else { return false }
        return readOnlyAllowlist.contains(first) && !isDangerous(command)
    }
}
