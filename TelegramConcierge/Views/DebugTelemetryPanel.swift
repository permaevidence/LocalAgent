import SwiftUI

/// User-only diagnostic panel showing a real-time log of agent activity:
/// tool starts/ends, turn lifecycle, background completions, etc.
///
/// This data is NEVER sent to the LLM — it lives purely in the UI layer and
/// is sourced from `DebugTelemetry.shared`.
struct DebugTelemetryPanel: View {
    @ObservedObject var telemetry = DebugTelemetry.shared
    @State private var expandedEventId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Telemetry").font(.headline)
                Spacer()
                Toggle("Verbose", isOn: $telemetry.verbose)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Toggle("Pin to bottom", isOn: $telemetry.pinToBottom)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Button("Clear") { telemetry.clear() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Scrollable log
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(telemetry.events) { event in
                            eventRow(event)
                                .id(event.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expandedEventId = (expandedEventId == event.id) ? nil : event.id
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: telemetry.events.count) { _, _ in
                    if telemetry.pinToBottom, let last = telemetry.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 280)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func eventRow(_ event: DebugTelemetry.Event) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: iconName(for: event.kind))
                    .foregroundStyle(color(for: event))
                    .font(.caption)
                Text(event.summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(for: event))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let ms = event.durationMs {
                    Text("\(ms)ms")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if expandedEventId == event.id, let detail = event.detail {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func iconName(for kind: DebugTelemetry.Kind) -> String {
        switch kind {
        case .toolStart: return "play.circle"
        case .toolEnd: return "checkmark.circle"
        case .toolError: return "xmark.circle"
        case .turnStart: return "arrow.right.circle"
        case .turnEnd: return "checkmark.seal"
        case .turnCancelled: return "stop.circle"
        case .turnError: return "exclamationmark.triangle"
        case .subagentSpawn: return "sparkles"
        case .subagentComplete: return "sparkles"
        case .bashSpawn: return "terminal"
        case .bashComplete: return "terminal"
        case .watchMatch: return "eye"
        case .pollTick: return "clock"
        case .busyReply: return "hourglass"
        case .messageDrop: return "trash"
        case .info: return "info.circle"
        }
    }

    private func color(for event: DebugTelemetry.Event) -> Color {
        if event.isError { return .red }
        switch event.kind {
        case .toolStart, .turnStart, .subagentSpawn, .bashSpawn: return .blue
        case .toolEnd, .turnEnd, .subagentComplete, .bashComplete: return .green
        case .toolError, .turnError, .messageDrop: return .red
        case .turnCancelled, .busyReply: return .orange
        case .watchMatch: return .purple
        case .pollTick, .info: return .secondary
        }
    }
}

#Preview {
    DebugTelemetryPanel()
        .frame(width: 360, height: 500)
}
