import AppKit
import SwiftUI

struct DashboardView: View {
    let store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.statuses) { status in
                        ProfileCard(status: status)
                    }
                }
                .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 410, height: 530)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexMeter")
                    .font(.headline)
                Text("Live main Codex quotas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
        }
        .padding(12)
    }
}

private struct ProfileCard: View {
    let status: ProfileStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status.profile.displayName)
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                if status.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else if let plan = status.snapshot?.planType {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = status.snapshot {
                QuotaWindowRow(title: "5 hours", window: snapshot.shortWindow)
                QuotaWindowRow(title: "Weekly", window: snapshot.weeklyWindow)

                HStack(spacing: 4) {
                    Image(systemName: status.isStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(status.isStale ? "Stale result" : "Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption2)
                .foregroundStyle(status.isStale ? .orange : .secondary)
            } else if status.errorMessage == nil {
                Text("Waiting for the first live response…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = status.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QuotaWindowRow: View {
    let title: String
    let window: QuotaWindow?

    var body: some View {
        if let window {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(Int(window.remainingPercent.rounded()))% remaining")
                        .fontWeight(.medium)
                }
                .font(.caption)

                ProgressView(value: window.remainingPercent, total: 100)
                    .tint(color(for: window.remainingPercent))

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(resetDescription(window.resetsAt, relativeTo: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text(title)
                Spacer()
                Text("Not returned for main quota")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func color(for remainingPercent: Double) -> Color {
        if remainingPercent <= 5 { return .red }
        if remainingPercent <= 20 { return .orange }
        return .green
    }

    private func resetDescription(_ resetDate: Date, relativeTo now: Date) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let countdown = relative.localizedString(for: resetDate, relativeTo: now)
        let exact = resetDate.formatted(date: .abbreviated, time: .shortened)
        return "Resets \(countdown) · \(exact)"
    }
}
