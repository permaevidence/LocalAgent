import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var conversationManager: ConversationManager
    @State private var scrollProxy: ScrollViewProxy?
    @State private var fileDescriptions: [String: String] = [:]
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    /// User-only debug telemetry panel visibility. The telemetry data is never
    /// sent to the LLM — it's a pure UI diagnostic.
    @State private var showTelemetry = true

    var body: some View {
        HSplitView {
            mainContent
                .frame(minWidth: 400, idealWidth: 520)
            if showTelemetry {
                DebugTelemetryPanel()
                    .frame(minWidth: 280, idealWidth: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadFileDescriptionsAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProjectsZipAutoExtractor.invalidRootFilesDetectedNotification)) { notification in
            guard let filenames = notification.userInfo?["filenames"] as? [String], !filenames.isEmpty else { return }
            let preview = filenames.prefix(5).joined(separator: ", ")
            let extraCount = max(0, filenames.count - 5)
            let filesText = extraCount > 0 ? "\(preview), +\(extraCount) more" : preview
            presentAlert(
                title: "Unsupported Files in Projects Folder",
                message: "Only folders or .zip files are supported directly in this location. Move these file(s) into a folder or zip archive: \(filesText)"
            )
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Main Content (chat column)

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            if conversationManager.isPrivacyModeEnabled {
                privacyModeView
            } else {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(conversationManager.messages.enumerated()), id: \.element.id) { index, message in
                                VStack(spacing: 8) {
                                    // Date separator (when day changes)
                                    if shouldShowDateHeader(at: index) {
                                        dateSeparator(for: message.timestamp)
                                    }

                                    MessageBubbleView(
                                        message: message,
                                        imageURLs: conversationManager.imageURLs(for: message),
                                        referencedImageURLs: conversationManager.referencedImageURLs(for: message),
                                        fileDescriptions: fileDescriptions
                                    )
                                }
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                    .onChange(of: conversationManager.messages.count) { _, _ in
                        scrollToBottom()
                        loadFileDescriptions()
                    }
                }
            }

            Divider()

            // Status bar
            statusBar
        }
    }

    // MARK: - Date Separator

    private var privacyModeView: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Conversation Hidden")
                .font(.title3.weight(.semibold))

            Text("Privacy mode was enabled from Telegram. Send `/show` to make the conversation visible again.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func shouldShowDateHeader(at index: Int) -> Bool {
        let messages = conversationManager.messages
        guard index < messages.count else { return false }
        
        if index == 0 { return true }
        
        let calendar = Calendar.current
        let currentDate = messages[index].timestamp
        let previousDate = messages[index - 1].timestamp
        return !calendar.isDate(currentDate, inSameDayAs: previousDate)
    }
    
    private func dateSeparator(for date: Date) -> some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
            
            Text(formatDateHeader(date))
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)
                .fixedSize()
            
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
    
    private func formatDateHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }
    
    // MARK: - File Descriptions
    
    private func loadFileDescriptions() {
        Task {
            await loadFileDescriptionsAsync()
        }
    }
    
    private func loadFileDescriptionsAsync() async {
        let descriptions = await FileDescriptionService.shared.getAll()
        await MainActor.run {
            fileDescriptions = descriptions
        }
    }
    
    // MARK: - Header
    
    @State private var telemetryHover = false
    
    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Chat")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(conversationManager.isPolling ? "Connected" : "Disconnected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                headerIconButton(
                    systemImage: showTelemetry ? "sidebar.right" : "sidebar.squares.right",
                    helpText: showTelemetry ? "Hide telemetry panel" : "Show telemetry panel",
                    isHovering: $telemetryHover,
                    action: { showTelemetry.toggle() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(conversationManager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Context token gauge
            Text(contextGaugeText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(contextGaugeColor)
                .help("Current context tokens / max context budget")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var contextGaugeText: String {
        let current = conversationManager.lastPromptTokens
        let max = conversationManager.maxContextTokens
        let currentStr = current.map { formatTokenCount($0) } ?? "—"
        let maxStr = formatTokenCount(max)
        return "\(currentStr)/\(maxStr)"
    }

    private var contextGaugeColor: Color {
        guard let current = conversationManager.lastPromptTokens else { return .secondary }
        let max = conversationManager.maxContextTokens
        let ratio = Double(current) / Double(max)
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .secondary
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M"
                : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(count)"
    }
    
    private var statusColor: Color {
        if conversationManager.error != nil {
            return .red
        } else if conversationManager.isPolling {
            return .green
        } else {
            return .gray
        }
    }
    
    private func scrollToBottom() {
        if let lastMessage = conversationManager.messages.last {
            withAnimation(.easeOut(duration: 0.3)) {
                scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    private func headerIconButton(
        systemImage: String,
        helpText: String,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering.wrappedValue ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isHovering.wrappedValue
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(isHovering.wrappedValue
                                ? Color.secondary.opacity(0.2)
                                : Color.clear, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering.wrappedValue = hovering
            }
        }
        .help(helpText)
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    ContentView()
        .environmentObject(ConversationManager())
}
