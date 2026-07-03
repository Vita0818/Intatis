//
//  IntatisMacRootView.swift
//  IntatisMac
//
//  The new shell: a NavigationSplitView with a branded gold sidebar (Chat / Code /
//  Cowork + Settings) over a warm page gradient. Replaces the old toolbar-picker
//  RootView. Code / Cowork reuse the existing containers for now; Chat is the fully
//  restyled vertical slice.
//

#if canImport(SwiftUI)
import SwiftUI
import IntatisCore

enum IntatisNavItem: String, CaseIterable, Identifiable, Hashable {
    case chat, code, cowork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:   return "Chat"
        case .code:   return "Code"
        case .cowork: return "Cowork"
        }
    }

    /// Chinese gloss shown next to the English label, family-style.
    var subtitle: String {
        switch self {
        case .chat:   return "对话"
        case .code:   return "编码"
        case .cowork: return "协作"
        }
    }

    var icon: String {
        switch self {
        case .chat:   return "bubble.left.and.bubble.right"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.2"
        }
    }
}

struct IntatisMacRootView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @State private var selection: IntatisNavItem = .chat
    @State private var isSettings = false
    @State private var didInit = false

    private var items: [IntatisNavItem] {
        IntatisNavItem.allCases.filter { item in
            switch item {
            case .chat:   return true
            case .code:   return PlatformProfile.current.supports(.code)
            case .cowork: return PlatformProfile.current.supports(.cowork)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            IntatisSidebar(items: items, selection: $selection, isSettings: $isSettings)
                .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 280)
        } detail: {
            ZStack {
                IntatisTheme.pageGradient(scheme).ignoresSafeArea()
                detail
            }
        }
        .navigationTitle("")
        .frame(minWidth: 1040, minHeight: 680)
        .task {
            guard !didInit else { return }
            didInit = true
            if env.needsAPIKey { isSettings = true }
        }
    }

    @ViewBuilder private var detail: some View {
        if isSettings {
            IntatisSettingsPanel()
        } else {
            switch selection {
            case .chat:   IntatisChatScreen(env: env)
            case .code:   CodeContainer(env: env)
            case .cowork: CoworkContainer(env: env)
            }
        }
    }
}

// MARK: - Sidebar

struct IntatisSidebar: View {
    let items: [IntatisNavItem]
    @Binding var selection: IntatisNavItem
    @Binding var isSettings: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Intatis")
                    .font(IntatisType.brand(28))
                    .foregroundStyle(IntatisTheme.deepText(scheme))
                Text("Mac")
                    .font(IntatisType.caption(12, .semibold))
                    .foregroundStyle(IntatisTheme.softText(scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

            VStack(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        selection = item
                        isSettings = false
                    } label: {
                        IntatisSidebarRow(item: item, selected: !isSettings && selection == item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            Button { isSettings = true } label: {
                IntatisSidebarSettingsRow(selected: isSettings)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background {
            Rectangle()
                .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.22 : 0.34))
                .background(.thinMaterial)
        }
    }
}

private struct IntatisSidebarRow: View {
    let item: IntatisNavItem
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? IntatisTheme.goldDeep : IntatisTheme.softText(scheme))
                .frame(width: 20)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title)
                    .font(IntatisType.body(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? IntatisTheme.deepText(scheme) : IntatisTheme.softText(scheme))
                Text(item.subtitle)
                    .font(IntatisType.caption(12, .regular))
                    .foregroundStyle(IntatisTheme.tertiaryText(scheme))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background { rowBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(IntatisTheme.gold.opacity(scheme == .dark ? 0.34 : 0.42), lineWidth: 1)
                .opacity(selected ? 1 : (hover ? 0.4 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { hover = $0 }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(selected ? AnyShapeStyle(selectedFill)
                           : AnyShapeStyle(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.16 : 0.30)))
            .opacity(selected || hover ? 1 : 0)
    }

    private var selectedFill: LinearGradient {
        LinearGradient(
            colors: [
                IntatisTheme.goldSoft.opacity(scheme == .dark ? 0.26 : 0.36),
                IntatisTheme.gold.opacity(scheme == .dark ? 0.18 : 0.22)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct IntatisSidebarSettingsRow: View {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? IntatisTheme.goldDeep : IntatisTheme.softText(scheme))
                .frame(width: 20)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Settings")
                    .font(IntatisType.body(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? IntatisTheme.deepText(scheme) : IntatisTheme.softText(scheme))
                Text("设置")
                    .font(IntatisType.caption(12, .regular))
                    .foregroundStyle(IntatisTheme.tertiaryText(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(IntatisTheme.glassSurface(scheme).opacity(scheme == .dark ? 0.16 : 0.30))
                .opacity(selected || hover ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(IntatisTheme.gold.opacity(scheme == .dark ? 0.34 : 0.42), lineWidth: 1)
                .opacity(selected ? 1 : (hover ? 0.4 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { hover = $0 }
    }
}
#endif
