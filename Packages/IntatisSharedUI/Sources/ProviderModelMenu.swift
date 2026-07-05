#if canImport(SwiftUI)
import SwiftUI

public struct ProviderModelMenuModel: Identifiable, Hashable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ProviderModelMenuProvider: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var models: [ProviderModelMenuModel]

    public init(id: String, title: String, models: [ProviderModelMenuModel]) {
        self.id = id
        self.title = title
        self.models = models
    }
}

public struct ProviderModelSelectionMenu<LabelContent: View>: View {
    private let providers: [ProviderModelMenuProvider]
    private let selectedProviderID: String
    private let selectedModelID: String
    private let isBusy: Bool
    private let onSelect: (String, String) -> Void
    private let label: () -> LabelContent

    public init(providers: [ProviderModelMenuProvider],
                selectedProviderID: String,
                selectedModelID: String,
                isBusy: Bool,
                onSelect: @escaping (String, String) -> Void,
                @ViewBuilder label: @escaping () -> LabelContent) {
        self.providers = providers
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.isBusy = isBusy
        self.onSelect = onSelect
        self.label = label
    }

    public var body: some View {
        Menu {
            ForEach(providers) { provider in
                Section(provider.title) {
                    ForEach(provider.models) { model in
                        Button {
                            onSelect(provider.id, model.id)
                        } label: {
                            Label(model.title,
                                  systemImage: isSelected(providerID: provider.id, modelID: model.id)
                                  ? "checkmark"
                                  : "circle")
                        }
                    }
                }
            }
        } label: {
            label()
        }
        .disabled(isBusy)
    }

    private func isSelected(providerID: String, modelID: String) -> Bool {
        selectedProviderID == providerID && selectedModelID == modelID
    }
}
#endif
