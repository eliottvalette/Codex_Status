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
        .frame(width: 533, height: 350)
    }
}

// MARK: - 2×2 Grid

private struct QuadrantGrid: View {
    let statuses: [ProfileStatus]
    let mostRecentID: String?

    private var shortResetRanks: [String: Int] {
        resetRanks { $0.snapshot?.shortWindow?.resetsAt }
    }

    private var weeklyResetRanks: [String: Int] {
        resetRanks { $0.snapshot?.weeklyWindow?.resetsAt }
    }

    private func resetRanks(resetsAt: (ProfileStatus) -> Date?) -> [String: Int] {
        let sorted = statuses
            .compactMap { status -> (String, Date)? in
                guard let date = resetsAt(status) else { return nil }
                return (status.id, date)
            }
            .sorted { $0.1 < $1.1 }
        return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.0, $0.offset + 1) })
    }

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
        let shortRanks = shortResetRanks
        let weeklyRanks = weeklyResetRanks

        if statuses.count >= 4 {
            AliasQuadrant(
                status: statuses[0],
                isMostRecent: statuses[0].id == mostRecentID,
                rank5H: shortRanks[statuses[0].id],
                rankWeek: weeklyRanks[statuses[0].id]
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW / 2, y: halfH / 2)

            AliasQuadrant(
                status: statuses[1],
                isMostRecent: statuses[1].id == mostRecentID,
                rank5H: shortRanks[statuses[1].id],
                rankWeek: weeklyRanks[statuses[1].id]
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW + halfW / 2, y: halfH / 2)

            AliasQuadrant(
                status: statuses[2],
                isMostRecent: statuses[2].id == mostRecentID,
                rank5H: shortRanks[statuses[2].id],
                rankWeek: weeklyRanks[statuses[2].id]
            )
            .frame(width: halfW, height: halfH)
            .position(x: halfW / 2, y: halfH + halfH / 2)

            AliasQuadrant(
                status: statuses[3],
                isMostRecent: statuses[3].id == mostRecentID,
                rank5H: shortRanks[statuses[3].id],
                rankWeek: weeklyRanks[statuses[3].id]
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
    let rank5H: Int?
    let rankWeek: Int?

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
            Text(status.profile.displayName)
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
                let diameter = max(50, min(geo.size.width, geo.size.height) - 46)
                QuotaGauge(
                    label: "WEEK",
                    window: status.snapshot?.weeklyWindow,
                    diameter: diameter,
                    resetRank: rankWeek
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                QuotaGauge(
                    label: "5H",
                    window: status.snapshot?.shortWindow,
                    diameter: 65,
                    resetRank: rank5H
                )
                .frame(maxWidth: .infinity)

                QuotaGauge(
                    label: "WEEK",
                    window: status.snapshot?.weeklyWindow,
                    diameter: 65,
                    resetRank: rankWeek
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
    let resetRank: Int?

    private var outerDiameter: CGFloat { diameter + 8 }

    private var remaining: Double? {
        window?.remainingPercent
    }

    private var ringColor: Color {
        guard let remaining else { return .secondary }
        let hue = (remaining / 100) * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.8, brightness: 0.85)
    }

    private func resetFraction(relativeTo now: Date) -> Double {
        guard let window else { return 0 }
        let windowSeconds = Double(window.durationMinutes) * 60
        let timeLeft = max(0, window.resetsAt.timeIntervalSince(now))
        return min(1, timeLeft / windowSeconds)
    }

    private func compactCountdown(_ date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let totalMinutes = Int(seconds / 60)
        let totalHours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if totalHours >= 48 {
            return "\(totalHours / 24)d"
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

    private func circledRank(_ rank: Int) -> String {
        ["①", "②", "③", "④"].indices.contains(rank - 1) ? ["①", "②", "③", "④"][rank - 1] : "\(rank)."
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1)

            if let remaining {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 3) {
                        ZStack {
                            // Outer track — reset proximity
                            Circle()
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 4)
                                .frame(width: outerDiameter, height: outerDiameter)

                            // Outer arc — time remaining until reset (full = far, empty = imminent)
                            Circle()
                                .trim(from: 0, to: resetFraction(relativeTo: context.date))
                                .stroke(
                                    Color.secondary.opacity(0.5),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                )
                                .frame(width: outerDiameter, height: outerDiameter)
                                .rotationEffect(.degrees(-90))

                            // Inner track — quota
                            Circle()
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 5)
                                .frame(width: diameter, height: diameter)

                            // Inner arc — remaining quota
                            Circle()
                                .trim(from: 0, to: remaining / 100)
                                .stroke(
                                    ringColor,
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                                )
                                .frame(width: diameter, height: diameter)
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.4), value: remaining)

                            Text("\(Int(remaining.rounded()))%")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(remaining <= 5 ? ringColor : .primary)
                        }
                        .frame(width: outerDiameter, height: outerDiameter)

                        HStack(spacing: 2) {
                            if let rank = resetRank {
                                Text(circledRank(rank))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(compactCountdown(window!.resetsAt, relativeTo: context.date))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
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
