#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisTools
import IntatisMCP
import IntatisSharedUI
import IntatisKnowledge
#if canImport(AppKit)
import AppKit
#endif

/// Wires process-wide provider configuration to the application-owned session
/// runtime registry. Window views only select which retained runtime to show.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: AppProviderCatalog
    @Published private(set) var inferenceProfileOptions: [AppInferenceProfileOption]
    @Published private(set) var inferenceCatalogError: String?
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    @Published private(set) var projects: [ProjectFolderRecord]
    @Published private(set) var projectStoreError: String?
    @Published var needsAPIKey: Bool

    let runtimeManager: AppSessionRuntimeManager
    let mcp: AppMCPService
    private var chatRuntime: AppChatSessionRuntime
    private let secrets: ConfigSecretResolver
    private let inferenceCatalogStore: InferenceCatalogStore
    private var inferenceCatalogSnapshot: InferenceCatalogSnapshot?

    init(runtimeManager: AppSessionRuntimeManager) {
        PlatformProfile.current = AppConfig.platformProfile

        let initialProjects: [ProjectFolderRecord]
        let initialProjectStoreError: String?
        do {
            initialProjects = try ProjectFolderStore.load(
                root: AppConfig.appSupportDir()).projects
            initialProjectStoreError = nil
        } catch {
            initialProjects = []
            initialProjectStoreError = error.localizedDescription
        }

        self.runtimeManager = runtimeManager
        self.mcp = AppMCPService()
        self.secrets = ConfigSecretResolver()
        self.inferenceCatalogStore = InferenceCatalogStore(
            fileURL: AppConfig.appSupportDir()
                .appendingPathComponent("inference-catalog-v1.json"))
        self.inferenceCatalogSnapshot = nil
        self.inferenceProfileOptions = []
        self.inferenceCatalogError = nil
        self.providerCatalog = AppConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: nil)
        self.registry = initialRegistry
        let initialSession = AppConfig.recentSessions(kind: .chat).first?.id ?? AppConfig.defaultSession
        self.chatSessionID = initialSession
        let initialChatRuntime: AppChatSessionRuntime
        do {
            initialChatRuntime = try runtimeManager.chatRuntime(
                sessionID: initialSession,
                registry: initialRegistry)
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        self.chatRuntime = initialChatRuntime
        self.viewModel = initialChatRuntime.viewModel
        self.projects = initialProjects
        self.projectStoreError = initialProjectStoreError
        self.needsAPIKey = !Self.hasAPIKey(ref: AppConfig.selectedAPIKeyRef)

        Task { [weak self] in
            guard let self else { return }
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: self.chatRuntime.log,
                kind: .chat)
            await self.refreshInferenceCatalog()
        }
    }

    func startNewChatSession() {
        do {
            try switchChatSession(to: SessionID.new())
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not start chat session: %@",
                error.localizedDescription)
        }
    }

    func resumeChatSession(_ session: AppSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not resume chat session: %@",
                error.localizedDescription)
        }
    }

    func recentChatSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .chat)
    }

    @discardableResult
    func addProject(
        workspace: WorkspaceAccessLease,
        kind: SessionKind
    ) throws -> ProjectFolderRecord {
        let project = try ProjectFolderStore.add(
            root: AppConfig.appSupportDir(),
            kind: kind,
            path: workspace.canonicalPath)
        refreshProjects()
        return project
    }

    func removeProject(_ projectID: ProjectID) throws {
        try ProjectFolderStore.remove(
            root: AppConfig.appSupportDir(),
            projectID: projectID)
        refreshProjects()
    }

    func refreshProjects() {
        do {
            projects = try ProjectFolderStore.load(
                root: AppConfig.appSupportDir()).projects
            projectStoreError = nil
        } catch {
            projectStoreError = error.localizedDescription
        }
    }

    @discardableResult
    func startNewProjectChatSession(
        projectID: ProjectID
    ) throws -> ProjectConversationReference {
        try validateProjectFolder(
            projectID: projectID,
            expectedKind: .chat)
        let session = SessionID.new()
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .chat)
        try associate(conversation, with: projectID)
        do {
            try switchChatSession(to: session)
            return conversation
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    func removeProjectConversation(
        _ conversation: ProjectConversationReference
    ) throws {
        try ProjectFolderStore.removeConversation(
            root: AppConfig.appSupportDir(),
            conversation: conversation)
        refreshProjects()
    }

    func deleteChatSession(_ session: SessionID) async throws {
        guard !runtimeManager.isBusy(kind: .chat, sessionID: session) else {
            throw IntatisError.io(IntatisLocalization.string(
                "Wait for the Chat response to finish before deleting this session."))
        }
        if session == chatSessionID {
            let replacement = recentChatSessions()
                .first(where: { $0.id != session })?.id
                ?? SessionID.new()
            try switchChatSession(to: replacement)
        }
        try await runtimeManager.removeSession(
            kind: .chat,
            sessionID: session,
            reason: "Chat session deleted by user"
        ) {
            try SessionHistoryStore.deleteSession(
                root: AppConfig.appSupportDir(),
                session: session)
        }
    }

    func handleRemovedChatRuntime(sessionID: SessionID) {
        guard chatSessionID == sessionID else { return }
        let replacement = recentChatSessions()
            .first(where: { $0.id != sessionID })?.id
            ?? SessionID.new()
        do {
            try switchChatSession(to: replacement)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "The removed Chat session could not be replaced: %@",
                error.localizedDescription)
        }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerID = providerCatalog.selectedProvider?.id ?? "default"
        do {
            try AppConfig.writeEditableProviderConfig(
                catalog: providerCatalog,
                apiKeysByProviderID: [providerID: trimmed])
        } catch {
            return
        }
        secrets.cache(trimmed, for: .authFile(providerID: providerID))
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = false
        refreshProviderRegistry()
        scheduleInferenceCatalogRefresh()
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(ref: .authFile(providerID: account))
    }

    func hasAPIKey(for provider: AppProviderSettings) -> Bool {
        Self.hasAPIKey(ref: AppConfig.apiKeyRef(for: provider))
    }

    func saveSettings(catalog rawCatalog: AppProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = AppConfig.normalizedCatalog(rawCatalog)
        var enteredAPIKeys: [String: String] = [:]
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
            enteredAPIKeys[provider.id] = key
            catalog.providers[index].apiKeySource = nil
        }
        if !enteredAPIKeys.isEmpty {
            try AppConfig.writeEditableProviderConfig(
                catalog: catalog,
                apiKeysByProviderID: enteredAPIKeys)
            for (providerID, key) in enteredAPIKeys {
                secrets.cache(key, for: .authFile(providerID: providerID))
            }
        }
        AppConfig.providerCatalog = catalog
        providerCatalog = AppConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))

        refreshProviderRegistry()
        scheduleInferenceCatalogRefresh()
    }

    func selectProviderModel(providerID: String, modelID: String, variantID: String?) {
        let catalog = AppConfig.selectProviderModel(
            providerID: providerID,
            modelID: modelID,
            variantID: variantID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(AppConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
        if inferenceCatalogSnapshot == nil {
            scheduleInferenceCatalogRefresh()
        }
    }

    func healthCheckSelectedProvider() async -> [ProviderHealthReport] {
        let options = ProviderHealthCheckOptions(timeoutSeconds: 15)
        let chat = await registry.healthCheck(role: .chat, options: options)
        let agent = await registry.healthCheck(role: .agent, options: options)
        return [chat, agent]
    }

    /// Build a fresh Code session bound to the chosen workspace folder.
    func makeCodeViewModel(workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        return try makeCodeViewModel(session: session, workspace: workspace)
    }

    func makeProjectCodeViewModel(
        projectID: ProjectID
    ) throws -> CodeViewModel {
        let workspace = try projectWorkspaceAccess(
            projectID: projectID,
            expectedKind: .code)
        let session = SessionID(rawValue: IDGen.random(prefix: "code"))
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .code)
        do {
            try associate(conversation, with: projectID)
        } catch {
            workspace.release()
            throw error
        }
        do {
            return try makeCodeViewModel(
                session: session,
                workspace: workspace)
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    func makeCodeViewModel(session: SessionID,
                           workspace: WorkspaceAccessLease) throws -> CodeViewModel {
        if let existing = runtimeManager.cachedCodeRuntime(sessionID: session) {
            workspace.release()
            return existing
        }
        let hadRememberedAccess = try WorkspaceAccess.hasRememberedAccess(
            forPath: workspace.canonicalPath,
            in: session)
        do {
            try WorkspaceAccess.remember(
                workspace.scopedURL,
                for: session,
                isPrimary: true)
            let codeLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            Task {
                _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                    in: codeLog,
                    kind: .code)
            }
            let runtime = CodeViewModel(
                sessionID: session,
                workspaceAccess: workspace,
                log: codeLog,
                artifactStore:
                    try ArtifactStore(
                        root:
                            AppConfig.artifactsDir(
                                session)),
                sessionNaming: makeSessionNamingService(log: codeLog, kind: .code),
                registry: registry,
                mcpSnapshots:
                    makeMCPSnapshotFactory(
                        kind: .code,
                        sessionID: session,
                        log: codeLog,
                        workspacePaths: [
                            workspace.canonicalPath,
                        ]),
                internalToolRegistryAugmenter:
                    makeKnowledgeToolAugmenter(),
                initialConfigurationNotice:
                    knowledgeToolsConfigurationNotice())
            return try runtimeManager.registerCodeRuntime(runtime)
        } catch {
            if !hadRememberedAccess {
                try? WorkspaceAccess.forget(
                    path: workspace.canonicalPath,
                    in: session,
                    allowPrimaryRemoval: true)
            }
            workspace.release()
            throw error
        }
    }

    /// Build a fresh multi-agent Cowork project session bound to a primary workspace.
    func makeCoworkViewModel(primaryWorkspace: WorkspaceAccessLease) async throws -> CoworkViewModel {
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        return try await makeCoworkViewModel(
            session: session,
            primaryWorkspace: primaryWorkspace)
    }

    func makeProjectCoworkViewModel(
        projectID: ProjectID
    ) async throws -> CoworkViewModel {
        let workspace = try projectWorkspaceAccess(
            projectID: projectID,
            expectedKind: .cowork)
        let session = SessionID(rawValue: IDGen.random(prefix: "cowork"))
        let conversation = ProjectConversationReference(
            sessionID: session,
            kind: .cowork)
        do {
            try associate(conversation, with: projectID)
        } catch {
            workspace.release()
            throw error
        }
        do {
            return try await makeCoworkViewModel(
                session: session,
                primaryWorkspace: workspace)
        } catch {
            rollbackProjectConversation(conversation)
            throw error
        }
    }

    private func makeCoworkViewModel(
        session: SessionID,
        primaryWorkspace: WorkspaceAccessLease
    ) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            primaryWorkspace.release()
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        guard let selectedBinding = AppInferenceCatalogCompiler.selectedBinding(
            catalog: providerCatalog,
            snapshot: inferenceCatalogSnapshot) else {
            primaryWorkspace.release()
            throw IntatisError.config(IntatisLocalization.string(
                "Choose a resolvable default inference profile before creating Cowork."))
        }
        // Codex App Server owns automatic approval review and binds it to the
        // selected Responses model through its official model catalog. The
        // legacy Intatis permission_reviewer_model is not a Cowork startup
        // dependency on the new kernel.
        let permissionReviewerBinding: AgentInferenceBinding? = nil
        do {
            try WorkspaceAccess.remember(
                primaryWorkspace.scopedURL,
                for: session,
                isPrimary: true)
            let settings = CoworkProjectSettings.fresh(
                sessionID: session,
                primaryWorkspace: primaryWorkspace.canonicalURL,
                catalog: providerCatalog,
                defaultInferenceProfileBinding: selectedBinding)
            let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
            return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
                try makeCoworkViewModel(
                    session: session,
                    log: coworkLog,
                    projectSettings: settings,
                    launchMode: .fresh,
                    initialWorkspaceAccess: primaryWorkspace,
                    permissionReviewerInferenceBinding:
                        permissionReviewerBinding)
            }
        } catch {
            try? WorkspaceAccess.forget(
                path: primaryWorkspace.canonicalPath,
                in: session,
                allowPrimaryRemoval: true)
            primaryWorkspace.release()
            throw error
        }
    }

    func makeCoworkViewModel(session: SessionID) async throws -> CoworkViewModel {
        guard let inferenceCatalogSnapshot else {
            throw IntatisError.config(
                inferenceCatalogError ?? IntatisLocalization.string(
                    "Inference profiles are still loading. Try again in a moment."))
        }
        let permissionReviewerBinding: AgentInferenceBinding? = nil
        return try await runtimeManager.coworkRuntime(sessionID: session) { [self] in
        let coworkLog = try EventLog(session: session, fileURL: AppConfig.sessionFile(session))
        let legacyOwnedWorkspacePaths = CoworkProjectSettingsStore
            .legacyOwnedWorkspacePaths(sessionID: session)
        let loaded = await CoworkProjectSettingsStore.loadAndMigrate(
            sessionID: session,
            log: coworkLog,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        var projectSettings = loaded.settings
        var warning = loaded.warning
        do {
            let projection = try await SessionProjectionStore.rebuild(from: coworkLog)
            let migrationAlreadyCompleted = projection.completedMigrations.contains {
                $0.migrationID == SessionProjectionStore.legacyWorkspaceAccessMigrationID
            }
            if migrationAlreadyCompleted {
                // Older/interrupted Phase S builds could have persisted a
                // symbolic-link spelling in EventLog while correctly keying
                // the capability plist by the canonical directory. Repair
                // only aliases proven through a live session bookmark.
                let mappings = try WorkspaceAccess.validatedCanonicalPathMappings(
                    for: projectSettings.workspaces.map(\.path),
                    in: session)
                projectSettings = try await persistValidatedWorkspacePathMappings(
                    mappings,
                    settings: projectSettings,
                    log: coworkLog)
                // The marker is appended only after the session-owned file was
                // read back successfully. Retrying cleanup here closes the
                // crash window between that durable marker and UserDefaults
                // deletion without ever re-importing shared capabilities.
                WorkspaceAccess.clearLegacySessionStorage(for: session)
                if loaded.legacySettingsCleanupEligible {
                    CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                }
            } else {
                let migration = try WorkspaceAccess.migrateLegacyBookmarks(
                    for: session,
                    workspacePaths: projectSettings.workspaces.map(\.path),
                    primaryPath: projectSettings.primaryWorkspace?.path,
                    sharedLegacyPaths: legacyOwnedWorkspacePaths)
                if migration.didMigrate {
                    projectSettings = try await persistValidatedWorkspacePathMappings(
                        migration.canonicalPathsByStoredPath,
                        settings: projectSettings,
                        log: coworkLog)
                    _ = try await SessionProjectionStore.recordMigration(
                        in: coworkLog,
                        migrationID: SessionProjectionStore.legacyWorkspaceAccessMigrationID,
                        source: .legacyWorkspaceUserDefaults)
                    WorkspaceAccess.clearLegacySessionStorage(for: session)
                    if loaded.legacySettingsCleanupEligible {
                        CoworkProjectSettingsStore.clearLegacyStorage(sessionID: session)
                    }
                }
            }
        } catch {
            let message = IntatisLocalization.format(
                "Legacy workspace access remains in compatibility mode: %@",
                error.localizedDescription)
            warning = warning.map { "\($0) \(message)" } ?? message
        }
        return try makeCoworkViewModel(
            session: session,
            log: coworkLog,
            projectSettings: projectSettings,
            launchMode: .restored,
            sessionStorageWarning: warning,
            permissionReviewerInferenceBinding:
                permissionReviewerBinding)
        }
    }

    private func persistValidatedWorkspacePathMappings(
        _ mappings: [String: String],
        settings: CoworkProjectSettings,
        log: EventLog
    ) async throws -> CoworkProjectSettings {
        guard !mappings.isEmpty else { return settings }
        var canonical = settings
        canonical.applyValidatedWorkspacePathMappings(mappings)
        guard canonical != settings else { return settings }
        let document = try await SessionProjectionStore.updateSettings(
            in: log,
            kind: .cowork,
            coworkSettings: canonical,
            changeKind: .migrated)
        guard let persisted = document.coworkSettings else {
            throw IntatisError.io(
                "Canonical workspace aliases were not persisted in session settings.")
        }
        return persisted
    }

    private func makeCoworkViewModel(
        session: SessionID,
        log coworkLog: EventLog,
        projectSettings: CoworkProjectSettings,
        launchMode: CoworkSessionLaunchMode,
        sessionStorageWarning: String? = nil,
        initialWorkspaceAccess: WorkspaceAccessLease? = nil,
        permissionReviewerInferenceBinding:
            AgentInferenceBinding?
    ) throws -> CoworkViewModel {
        let artifactStore = try ArtifactStore(root: AppConfig.artifactsDir(session))
        let permissionReviewerConfigurationError: String? = nil
        let combinedStorageWarning = [
            sessionStorageWarning,
            knowledgeToolsConfigurationNotice(),
        ].compactMap { $0 }.joined(separator: " ")
        return CoworkViewModel(
            sessionID: session,
            log: coworkLog,
            artifactStore: artifactStore,
            sessionNaming: makeSessionNamingService(log: coworkLog, kind: .cowork),
            registry: registry,
            inferenceProfileOptions: inferenceProfileOptions,
            permissionReviewerInferenceBinding:
                permissionReviewerInferenceBinding,
            permissionReviewerConfigurationError:
                permissionReviewerConfigurationError,
            projectSettings: projectSettings,
            launchMode: launchMode,
            sessionStorageWarning:
                combinedStorageWarning.isEmpty
                    ? nil
                    : combinedStorageWarning,
            initialWorkspaceAccess: initialWorkspaceAccess,
            mcpSnapshots:
                makeMCPSnapshotFactory(
                    kind: .cowork,
                    sessionID: session,
                    log: coworkLog,
                    workspacePaths:
                        projectSettings.workspaces
                            .map(\.path)),
            internalToolRegistryAugmenter:
                makeKnowledgeToolAugmenter())
    }

    private func configuredPermissionReviewerBinding(
        snapshot: InferenceCatalogSnapshot
    ) -> AgentInferenceBinding? {
        guard let reviewer = providerCatalog.permissionReviewerModel else {
            return nil
        }
        // The top-level role names a base provider/model profile. It never
        // borrows the mutable UI-selected variant or the current @main route.
        return AppInferenceCatalogCompiler.binding(
            providerID: reviewer.endpoint,
            modelID: reviewer.model.rawValue,
            variantID: nil,
            snapshot: snapshot)
    }

    private func makeKnowledgeToolAugmenter()
        -> HostToolRegistryAugmenter? {
        let configured = AppConfig.providerConfig()
        guard (try? ProviderRegistry.validateKnowledgeConfiguration(
            configured)) != nil else { return nil }
        let providerRegistry = registry
        let external = KnowledgeAccess.externalAuthorityProvider()
        return HostToolRegistryAugmenter(
            additionalCapabilities: [.buildKnowledge, .searchKnowledge]) { input in
                let models = try await providerRegistry.configuredKnowledgeModels()
                let embedding = try ProviderKnowledgeEmbeddingAdapter(
                    provider: models.embedding)
                let reranker = try ProviderKnowledgeRerankerAdapter(
                    provider: models.reranker)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                let host = try ModelDrivenKnowledgeToolHost(
                    embeddingProvider: embedding,
                    rerankerProvider: reranker,
                    authorityResolver: KnowledgeStoreAuthorityResolver(
                        externalProvider: external),
                    policy: KnowledgeSearchPolicy(
                        evaluationDate: formatter.string(from: Date())))
                return try await host.augment(input)
            }
    }

    private func knowledgeToolsConfigurationNotice() -> String? {
        do {
            try ProviderRegistry.validateKnowledgeConfiguration(
                AppConfig.providerConfig())
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func makeMCPSnapshotFactory(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        workspacePaths: [String]
    ) -> @MainActor @Sendable () async throws
        -> MCPAgentRequestToolSnapshotSource
    {
        { [weak self] in
            guard let self else {
                throw IntatisError.io(
                    "The application MCP runtime owner is unavailable.")
            }
            let runtime =
                try await self.mcpSessionRuntime(
                    kind: kind,
                    sessionID: sessionID,
                    log: log,
                    workspacePaths:
                        workspacePaths)
            return runtime.snapshots
        }
    }

    func mcpSessionRuntime(
        kind: SessionKind,
        sessionID: SessionID,
        log: EventLog,
        workspacePaths: [String]
    ) async throws -> MCPShippingSessionRuntime {
        let registry = self.registry
        let bindings = Set(
            inferenceProfileOptions.map(\.binding))
        let catalog = try await mcp.catalogStore.load()
        let allowedElicitationOrigins = Set<String>(
            catalog.heads.compactMap { head -> String? in
                guard !head.disabled,
                      let revision =
                        head.currentRevision,
                      let definition =
                        catalog.definition(
                            for:
                                MCPServerReference(
                                    serverID:
                                        head.serverID,
                                    serverRevision:
                                        revision)),
                      definition.configuration
                        .enabled,
                      case .streamableHTTP(
                        let configuration) =
                        definition.configuration
                            .transport
                else {
                    return nil
                }
                return configuration.canonicalOrigin
            })
        let runtimeIdentity =
            Self.mcpRuntimeIdentityFingerprint(
                kind: kind,
                sessionID: sessionID,
                workspacePaths: workspacePaths)
        let shipping =
            try await runtimeManager.mcpRuntime(
                kind: kind,
                sessionID: sessionID
            ) { [mcp] in
                let artifactStore =
                    try ArtifactStore(
                        root:
                            AppConfig.artifactsDir(
                                sessionID))
                return try await mcp
                    .makeShippingSessionRuntime(
                        sessionID: sessionID,
                        log: log,
                        artifactStore:
                            artifactStore,
                        runtimeIdentityFingerprint:
                            runtimeIdentity,
                        samplingPolicy:
                            MCPSamplingPolicy(
                                enabled:
                                    !bindings.isEmpty,
                                allowedInferenceBindings:
                                    bindings),
                        samplingInference:
                            MCPProviderSamplingInferenceService {
                                binding in
                                try await registry
                                    .agentInference(
                                        for: binding)
                            },
                        elicitationPolicy:
                            MCPElicitationPolicy(
                                formEnabled: true,
                                urlEnabled:
                                    !allowedElicitationOrigins
                                        .isEmpty,
                                allowedURLOrigins:
                                    allowedElicitationOrigins))
            }
        await mcp.synchronizeRuntimeObservation(
            sessionID: sessionID,
            owner: shipping.owner)
        return shipping
    }

    private static func mcpRuntimeIdentityFingerprint(
        kind: SessionKind,
        sessionID: SessionID,
        workspacePaths: [String]
    ) -> String {
        var fields = [
            "intatis-mac-mcp-runtime-v1",
            kind.rawValue,
            sessionID.rawValue,
        ]
        for path in Set(workspacePaths).sorted() {
            let canonical =
                URL(fileURLWithPath: path)
                    .standardizedFileURL.path
            fields.append(canonical)
            fields.append(
                WorkspaceRootIdentity.capture(
                    rootPath: canonical).map {
                        MCPHostDigest
                            .workspaceRootIdentity($0)
                    } ?? "missing-root")
        }
        return MCPHostDigest.sha256(fields)
    }

    private func makeSessionNamingService(
        log: EventLog,
        kind: SessionKind
    ) -> EventLogSessionNamingService {
        let manager = runtimeManager
        return EventLogSessionNamingService(log: log, kind: kind) { commit in
            await manager.publishSessionDisplayNameChange(AppSessionDisplayNameChange(
                key: AppSessionRuntimeKey(
                    kind: commit.kind,
                    sessionID: commit.sessionID),
                displayName: commit.displayName,
                settingsRevision: commit.settingsRevision,
                projectedThroughSeq: commit.projectedThroughSeq))
        }
    }

    private func projectWorkspaceAccess(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws -> WorkspaceAccessLease {
        let project = try projectRecord(
            projectID: projectID,
            expectedKind: expectedKind)
        guard let workspace = WorkspaceAccess.choose(
            prompt: IntatisLocalization.string("Choose Project Folder")) else {
            throw CancellationError()
        }
        guard workspace.canonicalPath == project.path else {
            workspace.release()
            throw IntatisError.io(IntatisLocalization.string(
                "Choose the exact folder registered for this project."))
        }
        return workspace
    }

    private func validateProjectFolder(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws {
        let project = try projectRecord(
            projectID: projectID,
            expectedKind: expectedKind)
        let url = try PathConfinement.canonicalExistingDirectory(
            URL(fileURLWithPath: project.path, isDirectory: true))
        guard url.path == project.path else {
            throw ProjectFolderStoreError.invalidProject
        }
    }

    private func projectRecord(
        projectID: ProjectID,
        expectedKind: SessionKind
    ) throws -> ProjectFolderRecord {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ProjectFolderStoreError.projectNotFound
        }
        guard project.kind == expectedKind else {
            throw ProjectFolderStoreError.invalidProject
        }
        return project
    }

    private func associate(
        _ conversation: ProjectConversationReference,
        with projectID: ProjectID
    ) throws {
        _ = try ProjectFolderStore.associate(
            root: AppConfig.appSupportDir(),
            projectID: projectID,
            conversation: conversation)
        refreshProjects()
    }

    private func rollbackProjectConversation(
        _ conversation: ProjectConversationReference
    ) {
        do {
            try ProjectFolderStore.removeConversation(
                root: AppConfig.appSupportDir(),
                conversation: conversation)
            refreshProjects()
        } catch {
            projectStoreError = error.localizedDescription
        }
    }

    func recentCodeSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .code)
    }

    func recentCoworkSessions() -> [AppSessionSummary] {
        AppConfig.recentSessions(kind: .cowork)
    }

    private func switchChatSession(to session: SessionID) throws {
        let runtime = try runtimeManager.chatRuntime(
            sessionID: session,
            registry: registry)
        self.chatRuntime = runtime
        self.viewModel = runtime.viewModel
        self.chatSessionID = session
        self.chatSessionError = nil
        Task {
            _ = try? await SessionProjectionStore.migrateLegacyDisplayName(
                in: runtime.log,
                kind: .chat)
        }
    }

    private static func makeProviderRegistry(
        resolver: ConfigSecretResolver,
        inferenceCatalogSnapshot: InferenceCatalogSnapshot?
    ) -> ProviderRegistry {
        ProviderRegistry(
            config: AppConfig.providerConfig(),
            resolver: resolver,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(
            resolver: secrets,
            inferenceCatalogSnapshot: inferenceCatalogSnapshot)
        registry = updated
        runtimeManager.updateProviderRegistry(
            updated,
            inferenceProfileOptions: inferenceProfileOptions)
    }

    private func scheduleInferenceCatalogRefresh() {
        Task { [weak self] in
            await self?.refreshInferenceCatalog()
        }
    }

    private func refreshInferenceCatalog() async {
        let sourceCatalog = providerCatalog
        do {
            let draft = try AppInferenceCatalogCompiler.compile(catalog: sourceCatalog)
            let snapshot = try await inferenceCatalogStore.reconcile(draft)
            guard sourceCatalog == providerCatalog else {
                scheduleInferenceCatalogRefresh()
                return
            }
            inferenceCatalogSnapshot = snapshot
            inferenceProfileOptions = AppInferenceCatalogCompiler.options(
                catalog: sourceCatalog,
                snapshot: snapshot)
            inferenceCatalogError = nil
            refreshProviderRegistry()
        } catch {
            // Keep a previously valid snapshot/registry alive for exact
            // bindings. Initial startup remains fail-closed until a valid
            // durable catalog can be loaded or reconciled.
            inferenceCatalogError = IntatisLocalization.format(
                "Versioned inference profiles are unavailable: %@",
                error.localizedDescription)
        }
    }

    private static func hasAPIKey(ref: KeychainRef) -> Bool {
        ConfigSecretResolver.exists(ref)
    }

}

// The shell lives in IntatisMacRootView; root-owned session state feeds the
// reusable workspace home and session views below.

struct WorkspaceSessionHome: View {
    let title: String
    let subtitle: String
    let icon: String
    let primaryTitle: String
    let primarySystemImage: String
    let primaryShortcut: KeyEquivalent?
    let error: String?
    let sessionsTitle: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let onPrimary: () -> Void
    let onResume: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    init(title: String,
         subtitle: String,
         icon: String,
         primaryTitle: String,
         primarySystemImage: String,
         primaryShortcut: KeyEquivalent? = nil,
         error: String?,
         sessionsTitle: String,
         sessions: [AppSessionSummary],
         workspacePath: @escaping (SessionID) -> String?,
         onPrimary: @escaping () -> Void,
         onResume: @escaping (AppSessionSummary) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.primaryTitle = primaryTitle
        self.primarySystemImage = primarySystemImage
        self.primaryShortcut = primaryShortcut
        self.error = error
        self.sessionsTitle = sessionsTitle
        self.sessions = sessions
        self.workspacePath = workspacePath
        self.onPrimary = onPrimary
        self.onResume = onResume
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = IntatisMacScreenLayout(rawWidth: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    IntatisPageHeader(title: title, subtitle: subtitle)

                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: icon)
                            .font(IntatisTypography.system(size: 28, weight: .semibold))
                            .foregroundStyle(IntatisTheme.accent(scheme))
                            .frame(width: 64, height: 64)
                        Text(primaryTitle)
                            .font(IntatisType.title(20))
                            .foregroundStyle(IntatisTheme.deepText(scheme))
                        primaryButton
                        if let error {
                            Text(error)
                                .font(IntatisType.caption(12))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                    .intatisCard(cornerRadius: 22)

                    if !sessions.isEmpty {
                        RecentSessionList(
                            title: sessionsTitle,
                            sessions: sessions,
                            workspacePath: workspacePath,
                            actionTitle: IntatisLocalization.string("Resume"),
                            onAction: onResume)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: layout.settingsMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        let button = Button(action: onPrimary) {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(IntatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .controlSize(.large)
        .intatisGlassButton(prominent: true)

        if let primaryShortcut {
            button.keyboardShortcut(primaryShortcut)
        } else {
            button
        }
    }
}

private struct RecentSessionList: View {
    let title: String
    let sessions: [AppSessionSummary]
    let workspacePath: (SessionID) -> String?
    let actionTitle: String
    let onAction: (AppSessionSummary) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(IntatisType.caption(12, .semibold))
                .foregroundStyle(IntatisTheme.softText(scheme))
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.id.rawValue)
                            .font(IntatisType.caption(12, .semibold))
                            .foregroundStyle(IntatisTheme.deepText(scheme))
                            .lineLimit(1)
                        Text(metadata(for: session))
                            .font(IntatisType.caption(11, .regular))
                            .foregroundStyle(IntatisTheme.softText(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(actionTitle) { onAction(session) }
                        .controlSize(.small)
                        .intatisGlassButton()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func metadata(for session: AppSessionSummary) -> String {
        let timestamp = session.updatedAt == .distantPast
            ? IntatisLocalization.string("Unknown date")
            : session.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let workspace = workspacePath(session.id).map { " · \($0)" } ?? ""
        let count = session.eventCount == 1
            ? IntatisLocalization.string("1 event")
            : IntatisLocalization.format("%lld events", Int64(session.eventCount))
        return "\(count) · \(timestamp)\(workspace)"
    }
}

struct CodeSessionView: View {
    @ObservedObject var vm: CodeViewModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let mcpProjectSettingsHost:
        MCPProjectSettingsHost
    let mcpContentHost:
        MCPConversationContentHost
    let onSelectModel: (String, String, String?) -> Void
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    @Binding var showsInspector: Bool
    @State private var showMCPProjectSettings =
        false
    @State private var showMCPContent = false
    @State private var showAttachmentImporter = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
            CodeShell(items: vm.items,
                      presentationScope: IntatisThreadPresentationScope(
                        kind: .code,
                        sessionID: vm.sessionID),
                      sessionTitle: sessionTitle,
                      thinkingScopeID: vm.sessionID.rawValue,
                      pending: vm.pendingPermission,
                  permissionNotice: vm.permissionNotice,
                  latestTurnStats: vm.latestTurnStats,
                  isWorking: vm.isWorking,
                  workspaceName: vm.workspaceName,
                  agentState: vm.agentState,
                  errorTexts: [
                    vm.voiceInput.errorText,
                    vm.composerError,
                  ].compactMap { $0 },
                  threadStyle: .intatisMac(scheme),
                  onShowSessions: onShowSessions,
                  onNewSession: onNewSession,
                  composerAccessory: AnyView(HStack(
                    alignment: .center,
                    spacing: IntatisComposerControlMetrics.rowSpacing
                  ) {
                    IntatisComposerModelControl(
                        catalog: catalog,
                        isBusy: vm.isWorking,
                        onSelectModel: onSelectModel)
                    MCPPendingExternalContextControl(
                        count:
                            vm.pendingMCPExternalContextCount,
                        onCancel: {
                            vm.cancelPendingMCPExternalContexts()
                        })
                    IntatisMacComposerAttachmentAccessory(
                        attachments: vm.draftAttachments,
                        accessibilityPrefix: "code",
                        isDisabled: vm.isWorking,
                        onAttach: {
                            showAttachmentImporter = true
                        },
                        onRemove: {
                            vm.removeDraftAttachment($0)
                        })
                  }),
                  composerTrailingAction:
                    IntatisThreadComposerSecondaryAction(
                        systemImage: vm.voiceInput.buttonSystemImage,
                        help: vm.voiceInput.buttonHelp,
                        isBusy: vm.voiceInput.showsProgress,
                        isDisabled: vm.voiceInput.isToggleDisabled
                            || (vm.isWorking
                                && !vm.voiceInput.isRecording),
                        blocksSubmission: vm.voiceInput.isEngaged,
                        action: { vm.toggleVoiceInput() }),
                  headerActions: [
                    IntatisThreadHeaderAction(
                        title: "MCP Content",
                        systemImage: "shippingbox.and.arrow.backward",
                        isIconOnly: true,
                        help: "Browse granted MCP resources, prompts, tasks, and calls",
                        accessibilityIdentifier: "code.mcp.content") {
                            showMCPContent = true
                        },
                    IntatisThreadHeaderAction(
                        title: "MCP Settings",
                        systemImage: "network.badge.shield.half.filled",
                        isIconOnly: true,
                        help: "Attach servers and manage exact Agent MCP grants",
                        accessibilityIdentifier: "code.mcp.settings") {
                            showMCPProjectSettings = true
                        },
                  ],
                  showsInspector: $showsInspector,
                  input: $vm.input,
                  onSend: { vm.send() },
                  onCancelCurrent: { vm.cancelCurrentTurn() },
                  onResolve: { vm.resolvePermission($0) })
            .sheet(isPresented: $showMCPContent) {
                MCPConversationCenterSheet(host: mcpContentHost)
            }
            .sheet(
                isPresented:
                    $showMCPProjectSettings
            ) {
                NavigationStack {
                    MCPProjectSettingsView(
                        host:
                            mcpProjectSettingsHost)
                        .navigationTitle(
                            "MCP Project Settings")
                }
                .frame(
                    minWidth: 980,
                    minHeight: 680)
            }
            .intatisComposerAttachmentImport(
                isPresented: $showAttachmentImporter,
                onImport: { vm.importDraftAttachments($0) },
                onFailure: { vm.reportAttachmentImportFailure($0) })
    }

}

struct CoworkSessionView: View {
    @ObservedObject var vm: CoworkViewModel
    @StateObject private var agentThreadPresentation:
        CoworkAgentThreadPresentationModel
    let sessionTitle: String
    let catalog: AppProviderCatalog
    let mcpProjectSettingsHost:
        MCPProjectSettingsHost
    let mcpContentHost:
        MCPConversationContentHost
    let onShowSessions: () -> Void
    let onNewSession: () -> Void
    let onSessionDidBecomeReady: () -> Void
    @Binding var showsInspector: Bool
    @State private var showProjectSettings = false
    @State private var showGoalEditor = false
    @State private var showGoalClearConfirmation = false
    @State private var goalObjectiveDraft = ""
    @State private var goalSuccessCriteriaDraft = ""
    @State private var goalConstraintsDraft = ""
    @State private var goalTokenBudgetDraft = ""
    @State private var goalEditorSubmissionError: String?
    @State private var showAttachmentImporter = false
    @Environment(\.colorScheme) private var scheme

    init(
        vm: CoworkViewModel,
        sessionTitle: String,
        catalog: AppProviderCatalog,
        mcpProjectSettingsHost: MCPProjectSettingsHost,
        mcpContentHost: MCPConversationContentHost,
        onShowSessions: @escaping () -> Void,
        onNewSession: @escaping () -> Void,
        onSessionDidBecomeReady: @escaping () -> Void,
        showsInspector: Binding<Bool>
    ) {
        self.vm = vm
        self.sessionTitle = sessionTitle
        self.catalog = catalog
        self.mcpProjectSettingsHost = mcpProjectSettingsHost
        self.mcpContentHost = mcpContentHost
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.onSessionDidBecomeReady = onSessionDidBecomeReady
        self._showsInspector = showsInspector
        self._agentThreadPresentation = StateObject(
            wrappedValue: CoworkAgentThreadPresentationModel(
                mainAgentID: vm.project.mainAgentName,
                loadPage: { [weak vm] agentID, upperBound in
                    guard let vm else {
                        return .empty(agentID: agentID)
                    }
                    return await vm.agentThreadPage(
                        agentID: agentID,
                        requestedUpperBound: upperBound)
                },
                updates: { [weak vm] agentID in
                    guard let vm else {
                        return AsyncStream { $0.finish() }
                    }
                    return vm.agentThreadUpdates(for: agentID)
                }))
    }

    private var hasMainAgent: Bool {
        vm.agents.contains { $0.name == vm.project.mainAgentName }
    }

    private var isCoworkBusy: Bool {
        vm.isAgentWorkActive || vm.isGoalContinuing
    }

    var body: some View {
        VStack(spacing: 0) {
            CoworkShell(threadPage: agentThreadPresentation.page,
                        presentationScope: IntatisThreadPresentationScope(
                            kind: .cowork,
                            sessionID: vm.sessionID),
                        sessionTitle: sessionTitle,
                        thinkingScopeID: vm.sessionID.rawValue,
                        agents: vm.agents,
                        pending: vm.pendingPermission,
                        permissionNotice: vm.permissionNotice,
                        latestTurnStats: vm.latestTurnStats,
                        summary: vm.summary,
                        project: vm.project,
                        goal: vm.goal,
                        workTasks: vm.workTasks,
                        errorTexts: [
                            vm.voiceInput.errorText,
                            vm.composerError,
                            vm.inferenceComposerError,
                            vm.projectionError,
                            vm.sessionStorageWarning,
                        ].compactMap { $0 },
                        isWorking: isCoworkBusy,
                        isAcceptingSubmission: vm.isAcceptingSubmission,
                        hasDraftAttachments: !vm.draftAttachments.isEmpty,
                        threadStyle: .intatisMac(scheme),
                        onShowSessions: onShowSessions,
                        onNewSession: onNewSession,
                        onShowProjectSettings: { showProjectSettings = true },
                        composerAccessory: AnyView(HStack(
                            alignment: .center,
                            spacing: IntatisComposerControlMetrics.rowSpacing
                        ) {
                            CoworkInferenceAccessory(
                                options: vm.inferenceProfileOptions,
                                selectedBinding: vm.nextMainInferenceBinding,
                                isDisabled: !hasMainAgent,
                                onSelect: { binding in
                                    vm.selectMainInferenceProfileForNextSubmission(binding)
                                })
                            MCPPendingExternalContextControl(
                                count:
                                    vm.pendingMCPExternalContextCount,
                                onCancel: {
                                    vm.cancelPendingMCPExternalContexts()
                                })
                        }),
                        composerInputAccessory: AnyView(
                            IntatisMacComposerAttachmentAccessory(
                                attachments: vm.draftAttachments,
                                accessibilityPrefix: "cowork",
                                onAttach: {
                                    showAttachmentImporter = true
                                },
                                onRemove: {
                                    vm.removeDraftAttachment($0)
                                })),
                        composerTrailingAction:
                            IntatisThreadComposerSecondaryAction(
                                systemImage:
                                    vm.voiceInput.buttonSystemImage,
                                help: vm.voiceInput.buttonHelp,
                                isBusy:
                                    vm.voiceInput.showsProgress,
                                isDisabled:
                                    vm.voiceInput.isToggleDisabled
                                    || (vm.isAcceptingSubmission
                                        && !vm.voiceInput.isRecording),
                                blocksSubmission:
                                    vm.voiceInput.isEngaged,
                                action: {
                                    vm.toggleVoiceInput()
                                }),
                        showsInspector: $showsInspector,
                        input: $vm.input,
                        onSend: { vm.send() },
                        onCancelCurrent: isCoworkBusy
                            ? { vm.cancelCurrentActivity() }
                            : nil,
                        onResolve: { vm.resolvePermission($0) },
                        onRemoveAgent: { vm.removeAgent(name: $0) },
                        onRetryTask: { vm.retryFailedTask(id: $0) },
                        onRetrySubmission: { vm.retrySubmission($0) },
                        onPauseGoal: { vm.pauseGoal() },
                        onResumeGoal: { vm.resumeGoal() },
                        onEditGoal: { presentGoalEditor() },
                        onClearGoal: { showGoalClearConfirmation = true },
                        selectedAgentID:
                            agentThreadPresentation.selectedAgentID,
                        isThreadPageLoading:
                            agentThreadPresentation.isLoading,
                        isRichRenderingEligible:
                            agentThreadPresentation.isRichRenderingEligible,
                        onSelectAgent: {
                            agentThreadPresentation.select($0)
                        },
                        onShowEarlier: {
                            agentThreadPresentation.showEarlier()
                        },
                        onShowNewer: {
                            agentThreadPresentation.showNewer()
                        },
                        onShowLatest: {
                            agentThreadPresentation.showLatest()
                        })
        }
        // SwiftUI preserves this view's structural identity when one Cowork
        // session replaces another. Key startup to the durable session ID so
        // the new view model cannot inherit the completed task of the old one.
        .onChange(of: hasMainAgent) { isReady in
            guard isReady else { return }
            // The first @main projection also means events.jsonl now exists,
            // so a history rescan can expose the new session in the sidebar.
            onSessionDidBecomeReady()
        }
        .onAppear {
            activateAgentThreadPresentation()
        }
        .onDisappear {
            agentThreadPresentation.deactivate()
        }
        .onChange(of: vm.agents) { _, _ in
            reconcileAgentThreadPresentation()
        }
        .onChange(of: vm.project.mainAgentName) { _, _ in
            reconcileAgentThreadPresentation()
        }
        .sheet(isPresented: $showProjectSettings) { projectSettingsSheet }
        .sheet(isPresented: $showGoalEditor) { goalEditorSheet }
        .intatisComposerAttachmentImport(
            isPresented: $showAttachmentImporter,
            onImport: { vm.importDraftAttachments($0) },
            onFailure: { vm.reportAttachmentImportFailure($0) })
        .alert("Clear this Goal?", isPresented: $showGoalClearConfirmation) {
            Button("Clear", role: .destructive) { vm.clearGoal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Goal card will be cleared without marking the Goal completed. Its durable history remains in the session log.")
        }
    }

    private func activateAgentThreadPresentation() {
        agentThreadPresentation.activate(
            mainAgentID: vm.project.mainAgentName,
            selectableAgentIDs: vm.agents
                .filter(\.isConversationSelectable)
                .map(\.id))
    }

    private func reconcileAgentThreadPresentation() {
        agentThreadPresentation.reconcile(
            mainAgentID: vm.project.mainAgentName,
            selectableAgentIDs: vm.agents
                .filter(\.isConversationSelectable)
                .map(\.id))
    }

    private var goalEditorValidationMessage: String? {
        if let goalEditorSubmissionError { return goalEditorSubmissionError }
        if goalObjectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return IntatisLocalization.string("A Goal objective is required.")
        }
        let budget = goalTokenBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty, Int(budget).map({ $0 > 0 }) != true {
            return IntatisLocalization.string(
                "Token budget must be a positive whole number, or left empty for no budget.")
        }
        return nil
    }

    private func presentGoalEditor() {
        guard let draft = vm.currentGoalEditDraft() else { return }
        goalObjectiveDraft = draft.objective
        goalSuccessCriteriaDraft = draft.successCriteria
        goalConstraintsDraft = draft.constraints
        goalTokenBudgetDraft = draft.tokenBudget
        goalEditorSubmissionError = nil
        showGoalEditor = true
    }

    private var projectSettingsSheet: some View {
        TabView {
            CoworkProjectSettingsSheet(
                vm: vm,
                catalog: catalog,
                inferenceProfileOptions:
                    vm.inferenceProfileOptions,
                onAddWorkspace: {
                    if let url = WorkspaceAccess.choose(
                        prompt:
                            IntatisLocalization.string(
                                "Choose Project Workspace"))
                    {
                        vm.addProjectWorkspace(url)
                    }
                })
                .tabItem {
                    Label(
                        "Project",
                        systemImage: "folder")
                }
            NavigationStack {
                MCPProjectSettingsView(
                    host:
                        mcpProjectSettingsHost,
                    contentHost:
                        mcpContentHost)
                    .navigationTitle(
                        "MCP Project Settings")
            }
            .tabItem {
                Label(
                    "MCP",
                    systemImage:
                        "network.badge.shield.half.filled")
            }
        }
        .frame(minWidth: 980, minHeight: 680)
    }

    private var goalEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Goal")
                .font(IntatisTypography.system(.title2, bold: true))
            Text("Edit the durable objective and its requirements. Enter one success criterion or constraint per line. Leaving token budget empty means no Goal budget. A paused Goal remains paused.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Objective")
                    .font(IntatisTypography.system(.caption, bold: true))
                TextEditor(text: $goalObjectiveDraft)
                    .font(IntatisTypography.system(.body))
                    .frame(minWidth: 500, minHeight: 90)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal objective")
                    .accessibilityIdentifier("cowork.goal.editor.objective")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Success criteria")
                        .font(IntatisTypography.system(.caption, bold: true))
                    Spacer()
                    Text("One per line")
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $goalSuccessCriteriaDraft)
                    .font(IntatisTypography.system(.body))
                    .frame(minHeight: 82)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal success criteria, one per line")
                    .accessibilityIdentifier("cowork.goal.editor.success_criteria")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Constraints")
                        .font(IntatisTypography.system(.caption, bold: true))
                    Spacer()
                    Text("One per line")
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $goalConstraintsDraft)
                    .font(IntatisTypography.system(.body))
                    .frame(minHeight: 82)
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                    .accessibilityLabel("Goal constraints, one per line")
                    .accessibilityIdentifier("cowork.goal.editor.constraints")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Token budget (optional)")
                    .font(IntatisTypography.system(.caption, bold: true))
                TextField("No budget", text: $goalTokenBudgetDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Optional positive Goal token budget")
                    .accessibilityIdentifier("cowork.goal.editor.token_budget")
            }

            if let validationMessage = goalEditorValidationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cowork.goal.editor.validation")
            }

            HStack {
                Spacer()
                Button("Cancel") { showGoalEditor = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cowork.goal.editor.cancel")
                Button("Save") {
                    if let error = vm.editGoal(
                        objective: goalObjectiveDraft,
                        successCriteria: goalSuccessCriteriaDraft,
                        constraints: goalConstraintsDraft,
                        tokenBudget: goalTokenBudgetDraft) {
                        goalEditorSubmissionError = error
                        return
                    }
                    showGoalEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(goalEditorValidationMessage != nil)
                .accessibilityIdentifier("cowork.goal.editor.save")
            }
        }
        .padding(22)
        .frame(width: 580)
        .accessibilityIdentifier("cowork.goal.editor")
        .onChange(of: goalObjectiveDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalSuccessCriteriaDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalConstraintsDraft) { _ in goalEditorSubmissionError = nil }
        .onChange(of: goalTokenBudgetDraft) { _ in goalEditorSubmissionError = nil }
    }
}

private struct CoworkInferenceAccessory: View {
    let options: [AppInferenceProfileOption]
    let selectedBinding: AgentInferenceBinding?
    let isDisabled: Bool
    let onSelect: (AgentInferenceBinding) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedOption: AppInferenceProfileOption? {
        guard let selectedBinding else { return nil }
        return options.first { $0.binding == selectedBinding }
    }

    private var modelLabel: String {
        selectedOption?.modelTitle ?? IntatisLocalization.string("Inference unavailable")
    }

    private var menuProviders: [ProviderModelMenuProvider] {
        Dictionary(grouping: options, by: \.providerID)
            .compactMap { providerID, providerOptions in
                guard let first = providerOptions.first else { return nil }
                return ProviderModelMenuProvider(
                    id: providerID,
                    title: first.providerTitle,
                    models: providerOptions.map { option in
                        ProviderModelMenuModel(
                            id: option.id,
                            modelID: option.modelID,
                            variantID: option.variantID,
                            title: option.modelTitle,
                            detail: option.variantTitle)
                    })
            }
            .sorted { lhs, rhs in
                [lhs.title, lhs.id].lexicographicallyPrecedes([rhs.title, rhs.id])
            }
    }

    var body: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: selectedOption?.providerID ?? "",
            selectedModelID: selectedOption?.modelID ?? "",
            selectedVariantID: selectedOption?.variantID,
            isBusy: isDisabled || options.isEmpty,
            onSelect: { providerID, modelID, variantID in
                guard let option = options.first(where: {
                    $0.providerID == providerID
                        && $0.modelID == modelID
                        && $0.variantID == variantID
                }) else { return }
                onSelect(option.binding)
            }) {
                HStack(spacing: 8) {
                    Text(modelLabel)
                        .font(IntatisType.body(13, .semibold))
                        .foregroundStyle(IntatisTheme.deepText(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(IntatisTypography.system(size: 10, weight: .semibold))
                        .foregroundStyle(IntatisTheme.tertiaryText(scheme))
                        .accessibilityHidden(true)
                }
                .intatisComposerSelectionLabel()
        }
        .intatisComposerSelectionMenu()
        .help(helpText)
        .accessibilityLabel(Text(IntatisLocalization.format(
            "Next @main model: %@",
            modelLabel)))
        .accessibilityIdentifier("cowork.main.inference-profile")
    }

    private var helpText: String {
        if options.isEmpty {
            return IntatisLocalization.string("No configured inference profiles are available")
        }
        if isDisabled {
            return IntatisLocalization.string(
                "@main must be attached before selecting its next model")
        }
        return IntatisLocalization.string(
            "Model for the next @main message. Current work and other agents keep their existing models.")
    }
}

#if canImport(AppKit)
@MainActor
final class IntatisApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    #if INTATIS_RENDERER_VALIDATION
    private var rendererValidationWindowController:
        NSWindowController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        IntatisMacProcessDiagnostics.shared.start(
            application: NSApplication.shared)
        #if INTATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-IntatisRendererFixture"),
              let rawSeconds = Self.argumentValue(
                  after: "-IntatisRendererFixtureAutoExitSeconds"),
              let seconds = Double(rawSeconds),
              (1...300).contains(seconds)
        else { return }
        let finalizeFixtureResult =
            RendererFixtureResultLifecycle.configure(
            arguments: arguments)
        _ = NSApplication.shared.setActivationPolicy(
            .regular)
        let controller = NSHostingController(
            rootView:
                RendererFixtureView(
                    arguments: arguments))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_280,
                height: 900),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.title =
            "Intatis Renderer Validation"
        window.center()
        let windowController =
            NSWindowController(
                window: window)
        rendererValidationWindowController =
            windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(
            ignoringOtherApps: true)

        // Keep watchdog auto-exit independent of SwiftUI view-task lifetime.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            _ = finalizeFixtureResult?()
            NSApplication.shared.terminate(nil)
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        IntatisMacProcessDiagnostics.shared.beginTermination()
        #if INTATIS_RENDERER_VALIDATION
        // The offline renderer fixture never creates AppEnvironment or session runtimes.
        // Let its watchdog-owned auto-exit complete inside the containment window
        // instead of paying the production runtime-drain deadline.
        if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
            RendererFixtureResultLifecycle.sealForExit()
            return .terminateNow
        }
        #endif
        let manager = AppSessionRuntimeManager.shared
        if manager.state == .stopped {
            return .terminateNow
        }
        guard terminationTask == nil else { return .terminateLater }
        let deadline: SessionRuntimeShutdownDeadline
        #if DEBUG
        if let raw = Self.argumentValue(after: "-IntatisShutdownDeadlineMilliseconds"),
           let milliseconds = Int64(raw), milliseconds >= 0 {
            deadline = .after(.milliseconds(milliseconds))
        } else {
            deadline = .after(.seconds(8))
        }
        #else
        deadline = .after(.seconds(8))
        #endif
        terminationTask = Task { @MainActor [weak self] in
            _ = await manager.shutdownAll(
                reason: "Application quit requested",
                deadline: deadline)
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        IntatisMacProcessDiagnostics.shared.beginTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func argumentValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif

@main
struct IntatisMacApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(IntatisApplicationDelegate.self)
    private var applicationDelegate
    #endif

    init() {
        IntatisTypography.prepareJetBrainsMonoTypography()
    }

    private var launchAppearance: ColorScheme? {
        #if DEBUG || INTATIS_RENDERER_VALIDATION
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-IntatisAppearanceDark") { return .dark }
        if arguments.contains("-IntatisAppearanceLight") { return .light }
        #endif
        return nil
    }

    #if DEBUG
    private var launchesCoworkAgentConversationFixture: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "-IntatisCoworkAgentConversationFixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(
                ".CoworkAgentConversationFixture") == true
    }

    private var launchesMessageFooterFixture: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(
            ".MessageFooterFixture") == true
    }

    private var documentSelectionFixtureStage: String? {
        let identifier = Bundle.main.bundleIdentifier
        if identifier?.hasSuffix(".DocumentSelectionFixture") == true {
            return "code-selection"
        }
        if identifier?.hasSuffix(".DocumentSelectionTableFixture") == true {
            return "table"
        }
        if identifier?.hasSuffix(".DocumentSelectionFullFixture") == true {
            return "full-static"
        }
        return nil
    }

    private var messageFooterFixtureArguments: [String] {
        return ProcessInfo.processInfo.arguments + [
            "-IntatisRendererFixtureStage",
            "message-footer",
        ]
    }
    private var documentSelectionFixtureArguments: [String] {
        guard let documentSelectionFixtureStage else {
            return ProcessInfo.processInfo.arguments
        }
        return ProcessInfo.processInfo.arguments + [
            "-IntatisRendererFixtureStage",
            documentSelectionFixtureStage,
        ]
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG || INTATIS_RENDERER_VALIDATION
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-IntatisPhaseLLifecycleFixture") {
                PhaseLSessionLifecycleFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-IntatisPhaseCPermissionFixture") {
                PhaseCPermissionFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if launchesCoworkAgentConversationFixture {
                CoworkAgentConversationFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else if launchesMessageFooterFixture {
                RendererFixtureView(
                    arguments: messageFooterFixtureArguments)
                    .preferredColorScheme(launchAppearance)
            } else if documentSelectionFixtureStage != nil {
                RendererFixtureView(
                    arguments: documentSelectionFixtureArguments)
                    .preferredColorScheme(launchAppearance)
            } else if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
                RendererFixtureView()
                    .preferredColorScheme(launchAppearance)
            } else {
                IntatisProductionRootView(launchAppearance: launchAppearance)
            }
            #else
            if ProcessInfo.processInfo.arguments.contains("-IntatisRendererFixture") {
                // The validation-only AppDelegate owns the single deterministic
                // NSHostingController fixture window. Keeping this scene inert
                // avoids running the exact workload twice while preserving the
                // normal Debug fixture scene unchanged.
                Color.clear
                    .accessibilityIdentifier(
                        "renderer.validation.host.placeholder")
                    .preferredColorScheme(launchAppearance)
            } else {
                IntatisProductionRootView(launchAppearance: launchAppearance)
            }
            #endif
            #else
            IntatisProductionRootView(launchAppearance: launchAppearance)
            #endif
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
private struct IntatisProductionRootView: View {
    @StateObject private var env: AppEnvironment
    let launchAppearance: ColorScheme?

    init(launchAppearance: ColorScheme?) {
        self.launchAppearance = launchAppearance
        _env = StateObject(wrappedValue: AppEnvironment(runtimeManager: .shared))
    }

    var body: some View {
        IntatisMacRootView(runtimeManager: env.runtimeManager)
            .environmentObject(env)
            .font(IntatisTypography.globalFont)
            .preferredColorScheme(launchAppearance)
    }
}
#else
// Non-Apple platforms (e.g. Linux CI building the whole package): provide a
// trivial entry point so the executable target still links.
@main
struct IntatisMacApp {
    static func main() {
        print("IntatisMac is a macOS SwiftUI app and only runs on macOS.")
    }
}
#endif
