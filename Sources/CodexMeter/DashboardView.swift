import AppKit
import SwiftUI

// MARK: - Root

private enum DashboardLayout {
    static let quadrantHeight: CGFloat = 198
    static let codexGridHeight: CGFloat = 2 * quadrantHeight
}

struct DashboardView: View {
    let store: UsageStore

    private var codexStatuses: [ProfileStatus] {
        store.statuses.filter { $0.profile.provider == .codex }
    }

    private var claudeStatuses: [ProfileStatus] {
        store.statuses.filter { $0.profile.provider == .claude }
    }

    var body: some View {
        VStack(spacing: 0) {
            if codexStatuses.isEmpty == false {
                QuadrantGrid(
                    statuses: codexStatuses,
                    mostRecentID: store.mostRecentProfileID,
                    onProfileRightClick: { profileID in
                        Task { await store.handleProfileTap(profileID) }
                    },
                    onProfileLeftClick: {
                        if store.transferSourceID != nil {
                            store.cancelTransferSelection()
                        }
                    }
                )
                .frame(height: DashboardLayout.codexGridHeight)
            }
            if codexStatuses.isEmpty == false && claudeStatuses.isEmpty == false {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
            }
            if claudeStatuses.isEmpty == false {
                ProfileRows(
                    statuses: claudeStatuses,
                    mostRecentID: store.mostRecentProfileID,
                    onProfileRightClick: { profileID in
                        Task { await store.handleProfileTap(profileID) }
                    },
                    onProfileLeftClick: {
                        if store.transferSourceID != nil {
                            store.cancelTransferSelection()
                        }
                    }
                )
            }
            if store.showsRecentChats {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                RecentChatsSection(store: store)
            }
            ControlRow(store: store)
        }
        .frame(width: 640)
        .onExitCommand {
            store.cancelTransferSelection()
        }
    }
}

// MARK: - Claude rows

/// Claude profiles are discovered at launch, so they are laid out two to a row
/// below the fixed Codex grid.
private struct ProfileRows: View {
    let statuses: [ProfileStatus]
    let mostRecentID: String?
    let onProfileRightClick: (String) -> Void
    let onProfileLeftClick: () -> Void

    private var rows: [[ProfileStatus]] {
        stride(from: 0, to: statuses.count, by: 2).map { start in
            Array(statuses[start..<min(start + 2, statuses.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 1)
                }
                HStack(spacing: 0) {
                    quadrant(row[0])
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                    if row.count > 1 {
                        quadrant(row[1])
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: DashboardLayout.quadrantHeight)
            }
        }
    }

    private func quadrant(_ status: ProfileStatus) -> some View {
        AliasQuadrant(
            status: status,
            isMostRecent: status.id == mostRecentID,
            onRightClick: onProfileRightClick,
            onLeftClick: onProfileLeftClick
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Recent Claude chats

/// The newest conversations across Claude accounts, each with a one-click copy to the
/// other accounts. The right-click copy of the three newest still works.
private struct RecentChatsSection: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RECENT CHATS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(1)

            if store.recentChats.isEmpty {
                Text("No Claude conversations yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(store.recentChats) { chat in
                            row(chat, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ chat: RecentClaudeChat, now: Date) -> some View {
        GridRow {
            Text(displayName(chat.profileID))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(RecentClaudeChat.ageLabel(since: chat.lastMessageAt, relativeTo: now))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)

            Text(chat.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(chat.folderName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)

            copyControl(chat)
        }
        .help(tooltip(chat))
    }

    @ViewBuilder
    private func copyControl(_ chat: RecentClaudeChat) -> some View {
        let destinations = store.claudeProfiles.filter { $0.id != chat.profileID }
        if destinations.count == 1, let destination = destinations.first {
            if chat.copiedToProfileIDs.contains(destination.id) {
                Text("✓ \(destination.displayName)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Already copied to \(destination.displayName)")
            } else {
                Button("→ \(destination.displayName)") {
                    Task { await store.copyChat(chat, to: destination.id) }
                }
                .font(.system(size: 11, design: .monospaced))
                .buttonStyle(.borderless)
                .disabled(store.isTransferring)
                .help("Copy this conversation to \(destination.displayName)")
            }
        } else {
            Menu("Copy to…") {
                ForEach(destinations) { destination in
                    let isCopied = chat.copiedToProfileIDs.contains(destination.id)
                    Button(isCopied ? "✓ \(destination.displayName)" : destination.displayName) {
                        Task { await store.copyChat(chat, to: destination.id) }
                    }
                    .disabled(isCopied)
                }
            }
            .font(.system(size: 11))
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isTransferring)
        }
    }

    private func displayName(_ profileID: String) -> String {
        store.claudeProfiles.first(where: { $0.id == profileID })?.displayName ?? profileID
    }

    private func tooltip(_ chat: RecentClaudeChat) -> String {
        [chat.title, chat.workingDirectory, "Session \(chat.file.sessionID)"]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

// MARK: - 2×2 Grid

private struct QuadrantGrid: View {
    let statuses: [ProfileStatus]
    let mostRecentID: String?
    let onProfileRightClick: (String) -> Void
    let onProfileLeftClick: () -> Void

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

        ForEach(Array(statuses.prefix(4).enumerated()), id: \.element.id) { index, status in
            AliasQuadrant(
                status: status,
                isMostRecent: status.id == mostRecentID,
                onRightClick: onProfileRightClick,
                onLeftClick: onProfileLeftClick
            )
            .frame(width: halfW, height: halfH)
            .position(
                x: halfW * (CGFloat(index % 2) + 0.5),
                y: halfH * (CGFloat(index / 2) + 0.5)
            )
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
    let onRightClick: (String) -> Void
    let onLeftClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            aliasHeader
            gaugeRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            ProfileTransferOverlay(
                profileID: status.id,
                isEnabled: status.errorMessage == nil || status.snapshot != nil,
                onRightClick: onRightClick,
                onLeftClick: onLeftClick,
                toolTip: status.errorMessage
            )
        }
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
        if let message = status.errorMessage, status.snapshot == nil {
            // No reading yet: a smaller ring leaves room to say why.
            GeometryReader { geo in
                let diameter = max(50, min(64, min(geo.size.width / 2 - 12, geo.size.height - 84)))
                VStack(spacing: 4) {
                    QuotaGauge(label: "WEEK", window: nil, diameter: diameter)
                        .accessibilityLabel("Account unavailable")
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if gauges.count == 1 {
            // Profile has no 5H quota — ring fills available space
            GeometryReader { geo in
                let diameter = max(50, min(84, min(geo.size.width - 16, geo.size.height - 44)))
                QuotaGauge(
                    label: gauges[0].label,
                    window: gauges[0].window,
                    diameter: diameter
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { geo in
                let availableWidthPerGauge = geo.size.width / CGFloat(gauges.count)
                let maxHorizontalDiameter = availableWidthPerGauge - 12
                let maxVerticalDiameter = geo.size.height - 44
                // Three rings share the box, so each gets a little less room.
                let maxDiameter: CGFloat = gauges.count > 2 ? 70 : 78
                let diameter = max(50, min(maxDiameter, min(maxHorizontalDiameter, maxVerticalDiameter)))

                HStack(spacing: 0) {
                    ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in
                        QuotaGauge(
                            label: gauge.label,
                            window: gauge.window,
                            diameter: diameter
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 5H when the plan has one, WEEK, then the tightest single-model weekly limit when
    /// one is in use. Codex accounts report no model limits, so they show one or two rings.
    private var gauges: [(label: String, window: QuotaWindow?)] {
        guard let snapshot = status.snapshot else {
            return [("5H", nil), ("WEEK", nil)]
        }
        var gauges: [(label: String, window: QuotaWindow?)] = []
        if let shortWindow = snapshot.shortWindow {
            gauges.append(("5H", shortWindow))
        }
        gauges.append(("WEEK", snapshot.weeklyWindow))
        if let model = snapshot.tightestModelWindow {
            gauges.append((model.label, model.window))
        }
        return gauges
    }
}

private struct ProfileTransferOverlay: NSViewRepresentable {
    let profileID: String
    let isEnabled: Bool
    let onRightClick: (String) -> Void
    let onLeftClick: () -> Void
    var toolTip: String? = nil

    func makeNSView(context: Context) -> ProfileClickView {
        ProfileClickView()
    }

    func updateNSView(_ nsView: ProfileClickView, context: Context) {
        nsView.onRightClick = {
            if isEnabled { onRightClick(profileID) }
        }
        nsView.onLeftClick = onLeftClick
        nsView.toolTip = toolTip
    }

    final class ProfileClickView: NSView {
        var onRightClick: (() -> Void)?
        var onLeftClick: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }

        override func mouseDown(with event: NSEvent) {
            onLeftClick?()
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
        guard let window else { return 0 }
        // An idle Claude window has no reset time yet, so check for idle first.
        if window.state == .dormant {
            return 1.0
        }
        guard let durationMinutes = window.durationMinutes, let resetsAt = window.resetsAt else {
            return 0
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
                VStack(spacing: 3) {
                    Circle()
                        .stroke(Color.gray.opacity(0.4), lineWidth: innerLineWidth)
                        .frame(width: diameter, height: diameter)
                        .frame(width: outerDiameter, height: outerDiameter)
                    Text("—")
                        .font(.system(size: labelFontSize, weight: .regular, design: .monospaced))
                        .hidden()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Quota unavailable")
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
                    let pace = store.paceValue(relativeTo: context.date)
                    Text(([updatedLabel(fetchedAt, relativeTo: context.date)] + [pace?.label].compactMap { $0 })
                        .joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("Combined usage rate since each account's weekly reset, relative to the sustainable rate across all accounts. 100% is sustainable. Recent resets can temporarily amplify the rate.")
                }
            }

            if let transferStatus {
                Text(transferStatus)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(store.transferFeedback?.detail ?? transferStatus)
            }

            Spacer()

            Button {
                Task { await store.syncRecentConversations() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .disabled(store.isTransferring)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Sync conversations from the last 10 days")
            .help("Sync conversations from the last 10 days")

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

    private var transferStatus: String? {
        if let feedback = store.transferFeedback {
            return feedback.message
        }
        guard
            let sourceID = store.transferSourceID,
            let source = store.statuses.first(where: { $0.id == sourceID })?.profile
        else {
            return nil
        }
        return "\(source.displayName) → right-click destination · left-click to cancel"
    }

    private func updatedLabel(_ date: Date, relativeTo now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "updated just now" }
        if minutes == 1 { return "updated 1m ago" }
        return "updated \(minutes)m ago"
    }
}
