#if canImport(SwiftUI)
import SwiftUI
import Foundation
import IntatisCore
import IntatisPermission
import IntatisSharedUI

struct CoworkProjectWorkspace: Identifiable, Codable, Equatable {
    var path: String
    var agentName: String?
    var isPrimary: Bool
    var addedAt: Date

    var id: String { path }

    init(path: String,
         agentName: String? = nil,
         isPrimary: Bool = false,
         addedAt: Date = Date()) {
        self.path = path
        self.agentName = agentName
        self.isPrimary = isPrimary
        self.addedAt = addedAt
    }
}

struct CoworkProjectSettings: Codable, Equatable {
    var sessionID: SessionID
    var mainAgentName: String
    var defaultProviderID: String?
    var defaultModelID: String?
    var defaultPermissionProfile: String
    var tokenBudget: Int?
    var workspaces: [CoworkProjectWorkspace]

    init(sessionID: SessionID,
         mainAgentName: String = "main",
         defaultProviderID: String? = nil,
         defaultModelID: String? = nil,
         defaultPermissionProfile: String = PermissionProfile.reviewed.rawValue,
         tokenBudget: Int? = nil,
         workspaces: [CoworkProjectWorkspace] = []) {
        self.sessionID = sessionID
        self.mainAgentName = mainAgentName
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.defaultPermissionProfile = defaultPermissionProfile
        self.tokenBudget = tokenBudget
        self.workspaces = workspaces
    }

    static func fresh(sessionID: SessionID,
                      primaryWorkspace: URL,
                      catalog: AppProviderCatalog) -> CoworkProjectSettings {
        CoworkProjectSettings(
            sessionID: sessionID,
            defaultProviderID: catalog.selectedProviderID,
            defaultModelID: catalog.selectedModelID,
            workspaces: [
                CoworkProjectWorkspace(
                    path: primaryWorkspace.standardizedFileURL.path,
                    agentName: "main",
                    isPrimary: true)
            ])
    }

    static func restored(sessionID: SessionID,
                         catalog: AppProviderCatalog) -> CoworkProjectSettings {
        CoworkProjectSettings(
            sessionID: sessionID,
            defaultProviderID: catalog.selectedProviderID,
            defaultModelID: catalog.selectedModelID)
    }

    var defaultProfile: PermissionProfile {
        PermissionProfile(rawValue: defaultPermissionProfile) ?? .reviewed
    }

    var primaryWorkspace: CoworkProjectWorkspace? {
        workspaces.first(where: \.isPrimary) ?? workspaces.first
    }

    mutating func upsertWorkspace(path: String,
                                  agentName: String?,
                                  isPrimary: Bool = false) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if isPrimary {
            for index in workspaces.indices {
                workspaces[index].isPrimary = false
            }
        }
        if let index = workspaces.firstIndex(where: { $0.path == normalizedPath }) {
            workspaces[index].agentName = agentName ?? workspaces[index].agentName
            workspaces[index].isPrimary = isPrimary || workspaces[index].isPrimary
            return
        }
        workspaces.append(CoworkProjectWorkspace(
            path: normalizedPath,
            agentName: agentName,
            isPrimary: isPrimary))
    }

    mutating func removeWorkspace(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        workspaces.removeAll { $0.path == normalizedPath }
    }

    mutating func removeWorkspaces(forAgent agentName: String) {
        workspaces.removeAll { $0.agentName == agentName && !$0.isPrimary }
    }
}

enum CoworkProjectSettingsStore {
    static func load(sessionID: SessionID,
                     catalog: AppProviderCatalog) -> CoworkProjectSettings {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)),
              let decoded = try? decoder.decode(CoworkProjectSettings.self, from: data) else {
            return CoworkProjectSettings.restored(sessionID: sessionID, catalog: catalog)
        }
        var settings = decoded
        settings.sessionID = sessionID
        if settings.mainAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.mainAgentName = "main"
        }
        if settings.defaultProviderID == nil {
            settings.defaultProviderID = catalog.selectedProviderID
        }
        if settings.defaultModelID == nil {
            settings.defaultModelID = catalog.selectedModelID
        }
        return settings
    }

    static func save(_ settings: CoworkProjectSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key(settings.sessionID))
    }

    static func primaryWorkspacePath(sessionID: SessionID) -> String? {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)),
              let decoded = try? decoder.decode(CoworkProjectSettings.self, from: data) else {
            return WorkspaceAccess.workspacePath(for: sessionID)
        }
        return decoded.primaryWorkspace?.path ?? WorkspaceAccess.workspacePath(for: sessionID)
    }

    static func remove(sessionID: SessionID) {
        UserDefaults.standard.removeObject(forKey: key(sessionID))
    }

    private static func key(_ sessionID: SessionID) -> String {
        "intatis.cowork.projectSettings.\(sessionID.rawValue)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct CoworkProjectSettingsSheet: View {
    @ObservedObject var vm: CoworkViewModel
    let catalog: AppProviderCatalog
    let onAddWorkspace: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var draft: CoworkProjectSettings
    @State private var tokenBudgetText: String
    @State private var settingsError: String?

    init(vm: CoworkViewModel,
         catalog: AppProviderCatalog,
         onAddWorkspace: @escaping () -> Void) {
        self.vm = vm
        self.catalog = catalog
        self.onAddWorkspace = onAddWorkspace
        _draft = State(initialValue: vm.projectSettings)
        _tokenBudgetText = State(initialValue: vm.projectSettings.tokenBudget.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cowork Project")
                        .font(.headline)
                    Text(vm.sessionID.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            settingsGrid

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Workspaces")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: addWorkspace) {
                        Label("Add Directory", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.isWorking)
                }
                workspaceList
            }

            if let settingsError {
                Text(settingsError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 620)
        .onChange(of: vm.projectSettings) { updated in
            draft = updated
            tokenBudgetText = updated.tokenBudget.map(String.init) ?? ""
        }
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            formRow("Main agent") {
                Text("@\(draft.mainAgentName)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }
            formRow("Default model") {
                Picker("", selection: modelSelectionBinding) {
                    ForEach(catalog.providers) { provider in
                        Section(provider.title) {
                            ForEach(provider.models) { model in
                                IntatisModelTitleLabel(model: model)
                                    .tag(modelSelectionKey(providerID: provider.id, modelID: model.id))
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            }
            formRow("Default permission") {
                Picker("", selection: $draft.defaultPermissionProfile) {
                    ForEach(permissionOptions, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }
            formRow("Soft token budget") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Unlimited", text: $tokenBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Text("Reserved before each request; provider tokenization and output-limit support may vary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
        }
    }

    private func formRow<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var workspaceList: some View {
        if vm.project.workspaces.isEmpty {
            Text("No workspace directories")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 7) {
                ForEach(vm.project.workspaces) { workspace in
                    HStack(spacing: 9) {
                        Image(systemName: workspace.isPrimary ? "house" : "folder")
                            .foregroundStyle(workspace.isPrimary ? IntatisTheme.accent(scheme) : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.displayName)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(workspace.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if let agentName = workspace.agentName {
                            Text("@\(agentName)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            remove(workspace)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.canRemove || vm.isWorking)
                        .help(workspace.canRemove ? "Remove workspace" : "Primary workspace is kept with @\(draft.mainAgentName)")
                    }
                    .padding(8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(IntatisTheme.separator(scheme), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: {
                modelSelectionKey(
                    providerID: draft.defaultProviderID ?? catalog.selectedProviderID,
                    modelID: draft.defaultModelID ?? catalog.selectedModelID)
            },
            set: { value in
                let parts = value.components(separatedBy: "::")
                guard parts.count >= 2 else { return }
                draft.defaultProviderID = parts[0]
                draft.defaultModelID = parts.dropFirst().joined(separator: "::")
            })
    }

    private func modelSelectionKey(providerID: String, modelID: String) -> String {
        "\(providerID)::\(modelID)"
    }

    private var permissionOptions: [(rawValue: String, title: String)] {
        [
            (PermissionProfile.reviewed.rawValue, "Reviewed"),
            (PermissionProfile.manual.rawValue, "Manual"),
            (PermissionProfile.readOnly.rawValue, "Read only"),
            (PermissionProfile.locked.rawValue, "Locked"),
        ]
    }

    private func addWorkspace() {
        dismiss()
        onAddWorkspace()
    }

    private func remove(_ workspace: CoworkWorkspaceInfo) {
        if let agentName = workspace.agentName {
            vm.removeAgent(name: agentName)
        } else {
            vm.removeWorkspace(path: workspace.path)
        }
    }

    private func save() {
        let trimmed = tokenBudgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft.tokenBudget = nil
        } else if let value = Int(trimmed), value > 0 {
            draft.tokenBudget = value
        } else {
            settingsError = "Soft token budget must be empty or a positive integer."
            return
        }
        settingsError = nil
        vm.updateProjectSettings(draft)
        dismiss()
    }
}
#endif
