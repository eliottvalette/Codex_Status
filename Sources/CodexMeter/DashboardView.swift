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
        .frame(width: 640, height: 420)
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

        if statuses.count >= 5 {
            AliasQuadrant(
                status: statuses[0],
                isMostRecent: statuses[0].id == mostRecentID
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW / 2, y: halfH / 2)

            AliasQuadrant(
                status: statuses[1],
                isMostRecent: statuses[1].id == mostRecentID
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW + halfW / 2, y: halfH / 2)

            AliasQuadrant(
                status: statuses[2],
                isMostRecent: statuses[2].id == mostRecentID
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW / 2, y: halfH + halfH / 2)

            SharedWeeklyQuadrant(
                leftStatus: statuses[3],
                rightStatus: statuses[4],
                leftMostRecent: statuses[3].id == mostRecentID,
                rightMostRecent: statuses[4].id == mostRecentID
            )
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
        VStack(alignment: .leading, spacing: 6) {
            aliasHeader
            gaugeRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var aliasHeader: some View {
        HStack(spacing: 4) {
            Text(status.headerTitle())
                .font(.system(size: 11, weight: isMostRecent ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isMostRecent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if status.isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
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
        } else if status.snapshot != nil, status.snapshot?.shortWindow == nil {
            // Profile has no 5H quota — ring fills available space
            GeometryReader { geo in
                let diameter = max(50, min(84, min(geo.size.width - 16, geo.size.height - 44)))
                QuotaGauge(
                    label: "WEEK",
                    window: status.snapshot?.weeklyWindow,
                    diameter: diameter
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { geo in
                let availableWidthPerGauge = geo.size.width / 2
                let maxHorizontalDiameter = availableWidthPerGauge - 12
                let maxVerticalDiameter = geo.size.height - 44
                let diameter = max(50, min(78, min(maxHorizontalDiameter, maxVerticalDiameter)))

                HStack(spacing: 0) {
                    QuotaGauge(
                        label: "5H",
                        window: status.snapshot?.shortWindow,
                        diameter: diameter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    QuotaGauge(
                        label: "WEEK",
                        window: status.snapshot?.weeklyWindow,
                        diameter: diameter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Shared weekly quadrant (codex-bio + codex-ster)

private struct SharedWeeklyQuadrant: View {
    let leftStatus: ProfileStatus
    let rightStatus: ProfileStatus
    let leftMostRecent: Bool
    let rightMostRecent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            gaugeRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack {
            HStack(spacing: 4) {
                Text(leftStatus.headerTitle())
                    .font(.system(size: 11, weight: leftMostRecent ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(leftMostRecent ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if leftStatus.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                if leftStatus.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if rightStatus.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                if rightStatus.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Text(rightStatus.headerTitle())
                    .font(.system(size: 11, weight: rightMostRecent ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(rightMostRecent ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private var gaugeRow: some View {
        GeometryReader { geo in
            let availableWidthPerGauge = geo.size.width / 2
            let maxHorizontalDiameter = availableWidthPerGauge - 12
            let maxVerticalDiameter = geo.size.height - 44
            let diameter = max(50, min(78, min(maxHorizontalDiameter, maxVerticalDiameter)))

            HStack(spacing: 0) {
                if let errorMessage = leftStatus.errorMessage, leftStatus.snapshot == nil {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuotaGauge(
                        label: "WEEK",
                        window: leftStatus.snapshot?.weeklyWindow,
                        diameter: diameter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let errorMessage = rightStatus.errorMessage, rightStatus.snapshot == nil {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuotaGauge(
                        label: "WEEK",
                        window: rightStatus.snapshot?.weeklyWindow,
                        diameter: diameter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Radial gauge

private struct QuotaGauge: View {
    let label: String
    let window: QuotaWindow?
    let diameter: CGFloat

    private var outerDiameter: CGFloat { diameter + 8 }
    private var outerLineWidth: CGFloat { 4 }
    private var innerLineWidth: CGFloat { 5 }
    private var percentFontSize: CGFloat { 15 }
    private var labelFontSize: CGFloat { 12 }

    private var remaining: Double? {
        window?.remainingPercent
    }

    private var ringColor: Color {
        guard let remaining else { return .secondary }
        let hue = (remaining / 100) * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.8, brightness: 0.85)
    }

    private func resetFraction(relativeTo now: Date) -> Double {
        guard let window, let durationMinutes = window.durationMinutes, let resetsAt = window.resetsAt else {
            return 0
        }
        if window.state == .dormant {
            return 1.0
        }
        let windowSeconds = Double(durationMinutes) * 60
        let timeLeft = max(0, resetsAt.timeIntervalSince(now))
        return min(1, timeLeft / windowSeconds)
    }

    private func compactCountdown(_ date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let totalMinutes = Int(seconds / 60)
        let totalHours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if totalHours >= 48 {
            return "\(totalHours / 24)d \(totalHours % 24)h"
        }
        if totalHours >= 6 {
            return "\(totalHours)h"
        }
        if totalHours >= 1 {
            return minutes > 0 ? "\(totalHours)h \(minutes)m" : "\(totalHours)h"
        }
        if totalMinutes >= 1 {
            return "\(totalMinutes)m"
        }
        return "<1m"
    }

    @ViewBuilder
    private func countdownView(for quotaWindow: QuotaWindow, relativeTo now: Date) -> some View {
        switch quotaWindow.state {
        case .dormant:
            Text("idle")
                .foregroundStyle(.secondary)
                .font(.system(size: labelFontSize, weight: .regular, design: .monospaced))
        case .active, .unknown:
            if let resetsAt = quotaWindow.resetsAt {
                Text(compactCountdown(resetsAt, relativeTo: now))
                    .foregroundStyle(.secondary)
                    .font(.system(size: labelFontSize, weight: .regular, design: .monospaced))
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
                    .font(.system(size: labelFontSize, weight: .regular, design: .monospaced))
            }
        case .unavailable:
            Text("—")
                .foregroundStyle(.secondary)
                .font(.system(size: labelFontSize, weight: .regular, design: .monospaced))
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: labelFontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1)

            if let remaining, let window {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.18), lineWidth: outerLineWidth)
                                .frame(width: outerDiameter, height: outerDiameter)

                            Circle()
                                .trim(from: 0, to: resetFraction(relativeTo: context.date))
                                .stroke(
                                    Color.secondary.opacity(0.5),
                                    style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .round)
                                )
                                .frame(width: outerDiameter, height: outerDiameter)
                                .rotationEffect(.degrees(-90))

                            Circle()
                                .stroke(Color.secondary.opacity(0.15), lineWidth: innerLineWidth)
                                .frame(width: diameter, height: diameter)

                            Circle()
                                .trim(from: 0, to: remaining / 100)
                                .stroke(
                                    ringColor,
                                    style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
                                )
                                .frame(width: diameter, height: diameter)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.4), value: remaining)

                            Text("\(Int(remaining.rounded()))%")
                                .font(.system(size: percentFontSize, weight: .semibold, design: .rounded))
                                .foregroundStyle(remaining <= 5 ? ringColor : .primary)
                        }
                        .frame(width: outerDiameter, height: outerDiameter)

                        countdownView(for: window, relativeTo: context.date)
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(height: outerDiameter)
            }
        }
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
        .frame(height: 24)
    }

    private func updatedLabel(_ date: Date, relativeTo now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "updated just now" }
        if minutes == 1 { return "updated 1m ago" }
        return "updated \(minutes)m ago"
    }
}
