import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case identity
    case telegram
    case llmProvider
    case services
    case mcps
    case agents
    case skills
    case data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .identity: return "Identity"
        case .telegram: return "Telegram"
        case .llmProvider: return "LLM Provider"
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
        case .telegram: return "paperplane.fill"
        case .llmProvider: return "brain.head.profile"
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
    @State private var selectedSection: AppSection = .chat

    var body: some View {
        HStack(spacing: 0) {
            sidebarView
            Divider()
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 13))
                                .frame(width: 20)
                            Text(section.label)
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedSection == section
                                      ? Color.accentColor.opacity(0.15)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedSection == section ? .primary : .secondary)
                }
            }
            .padding(8)

            Spacer()

            sidebarFooter
        }
        .frame(width: 200)
        .background(.ultraThinMaterial)
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
        switch selectedSection {
        case .chat:
            ContentView()
        case .agents:
            AgentsSettingsView()
        case .mcps:
            MCPsSettingsView()
        case .skills:
            SkillsSettingsView()
        case .identity, .telegram, .llmProvider, .services, .data:
            SettingsView(section: selectedSection)
        }
    }
}

#Preview {
    MainView()
        .environmentObject(ConversationManager())
}
