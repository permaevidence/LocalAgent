import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case identity
    case connection
    case services
    case agents
    case mcps
    case skills
    case data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .identity: return "Identity"
        case .connection: return "Connection"
        case .services: return "Services"
        case .agents: return "Agents"
        case .mcps: return "MCPs"
        case .skills: return "Skills"
        case .data: return "Data"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .identity: return "person.text.rectangle"
        case .connection: return "antenna.radiowaves.left.and.right"
        case .services: return "puzzlepiece.extension"
        case .agents: return "person.2.wave.2"
        case .mcps: return "server.rack"
        case .skills: return "wand.and.stars"
        case .data: return "externaldrive.fill"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var selectedSection: AppSection? = .chat

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selectedSection) { section in
                Label(section.label, systemImage: section.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar Footer

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(conversationManager.isPolling ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(conversationManager.isPolling ? "Active" : "Inactive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(conversationManager.isPolling ? .primary : .secondary)
                Spacer()
                Toggle(isOn: Binding(
                    get: { conversationManager.isPolling },
                    set: { newValue in
                        Task {
                            if newValue {
                                await conversationManager.startPolling()
                            } else {
                                conversationManager.stopPolling()
                            }
                        }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let section = selectedSection {
            switch section {
            case .chat:
                ContentView()
            case .agents:
                AgentsSettingsView()
            case .mcps:
                MCPsSettingsView()
            case .skills:
                SkillsSettingsView()
            case .identity, .connection, .services, .data:
                SettingsView(section: section)
            }
        } else {
            ContentView()
        }
    }
}

#Preview {
    MainView()
        .environmentObject(ConversationManager())
}
