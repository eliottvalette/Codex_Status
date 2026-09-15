import AppKit
import SwiftUI

// MARK: - Root

struct DashboardView: View {
    let store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            QuadrantGrid(statuses: store.statuses, mostRecentID: store.mostRecentProfileID)
            ControlRow(store: store)
        }
        .frame(width: 410, height: 470)
    }
}

// MARK: - 2×2 Grid

private struct QuadrantGrid: View {
    let statuses: [ProfileStatus]
    let mostRecentID: String?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .topLeading) {
                quadrantLayout(width: width, height: height)
                crossHairDividers(width: width, height: height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func quadrantLayout(width: CGFloat, height: CGFloat) -> some View {
        let halfW = width / 2
        let halfH = height / 2

        if statuses.count >= 4 {
            AliasQuadrant(status: statuses[0], isMostRecent: statuses[0].id == mostRecentID)
                .frame(width: halfW, height: halfH)
                .position(x: halfW / 2, y: halfH / 2)

            AliasQuadrant(status: statuses[1], isMostRecent: statuses[1].id == mostRecentID)
                .frame(width: halfW, height: halfH)
                .position(x: halfW + halfW / 2, y: halfH / 2)

            AliasQuadrant(status: statuses[2], isMostRecent: statuses[2].id == mostRecentID)
                .frame(width: halfW, height: halfH)
                .position(x: halfW / 2, y: halfH + halfH / 2)

            AliasQuadrant(status: statuses[3], isMostRecent: statuses[3].id == mostRecentID)
                .frame(width: halfW, height: halfH)
                .position(x: halfW + halfW / 2, y: halfH + halfH / 2)
        }
    }

    private func crossHairDividers(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: height)
                .position(x: width / 2, y: height / 2)

            Rectangle()
                .fill(.separator)
                .frame(width: width, height: 1)
                .position(x: width / 2, y: height / 2)
        }
    }
}

// MARK: - Single alias quadrant

private struct AliasQuadrant: View {
    let status: ProfileStatus
    let isMostRecent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            aliasHeader
            gaugeRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var aliasHeader: some View {
        HStack(spacing: 5) {
            if isMostRecent {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
            }
            Text(status.profile.displayName)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(isMostRecent ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if status.isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if status.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var gaugeRow: some View {
        if let errorMessage = status.errorMessage, status.snapshot == nil {
            Text(errorMessage)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 0) {
                QuotaGauge(
                    label: "5H",
                    window: status.snapshot?.shortWindow,
                    diameter: 62
                )
                .frame(maxWidth: .infinity)

                QuotaGauge(
                    label: "WEEK",
                    window: status.snapshot?.weeklyWindow,
                    diameter: 62
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Radial gauge

private struct QuotaGauge: View {
    let label: String
    let window: QuotaWindow?
    let diameter: CGFloat

    private var remaining: Double? {
        window.map { $0.remainingPercent }
    }

    private var ringColor: Color {
        guard let remaining else { return .secondary }
        if remaining > 40 { return .green }
        if remaining > 15 { return .yellow }
        if remaining > 5 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1)

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 5)
                    .frame(width: diameter, height: diameter)

                if let remaining, window != nil {
                    Circle()
                        .trim(from: 0, to: remaining / 100)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: diameter, height: diameter)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: remaining)
                }

                percentageLabel
            }

            resetLabel
        }
    }

    @ViewBuilder
    private var percentageLabel: some View {
        if let remaining {
            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(remaining <= 5 ? ringColor : .primary)
        } else {
            Text("—")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resetLabel: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let resetsAt = window?.resetsAt {
                Text(compactCountdown(resetsAt, relativeTo: context.date))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(" ")
                    .font(.system(size: 10))
            }
        }
    }

    private func compactCountdown(_ date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        let remainingHours = hours % 24
        let remainingMinutes = minutes % 60

        if days >= 2 {
            return "\(days)d"
        }
        if days == 1 {
            return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "1d"
        }
        if hours >= 1 {
            return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
        }
        if minutes >= 1 {
            return "\(minutes)m"
        }
        return "<1m"
    }
}

// MARK: - Control row

private struct ControlRow: View {
    let store: UsageStore

    private var oldestFetchedAt: Date? {
        store.statuses
            .compactMap(\.snapshot)
            .map(\.fetchedAt)
            .min()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let fetchedAt = oldestFetchedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updatedLabel(fetchedAt, relativeTo: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh (⌘R)")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit (⌘Q)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 24)
    }

    private func updatedLabel(_ date: Date, relativeTo now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "updated just now" }
        if minutes == 1 { return "updated 1m ago" }
        return "updated \(minutes)m ago"
    }
}
