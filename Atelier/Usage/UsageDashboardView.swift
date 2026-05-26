// SPDX-License-Identifier: MIT
import Charts
import SwiftUI

/// Full-page cross-project usage dashboard.
///
/// Pulls every Agent row from GRDB on appear, aggregates in-memory into the
/// four standard time windows (24h / 7d / 30d / all-time), then renders cost
/// + token totals, a per-model breakdown, and a daily-cost bar chart.
struct UsageDashboardView: View {
    @Bindable var store: AppStore

    @State private var records: [UsageRecord] = []
    @State private var atelierTracked: Int = 0
    @State private var historyTracked: Int = 0
    @State private var loading: Bool = true
    @State private var limits: UsageLimitsService.Limits?
    @State private var limitsError: String?
    @State private var limitsLoading = false
    @State private var dataNotesExpanded = false
    @AppStorage("usage.limitsOptIn") private var limitsOptIn = false
    @AppStorage("usage.dailyBudgetUsd") private var dailyBudgetUsd: Double = 0

    var body: some View {
        ZStack {
            Color.atelierBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                header
                if loading {
                    loadingState
                } else if records.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
        }
        .task { await load() }
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Usage")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                if !records.isEmpty {
                    Text("\(totalSessions) session\(totalSessions == 1 ? "" : "s")")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(String(format: "· $%.4f recorded", allTime.cost))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                        .help("What Atelier has recorded since you started using it — not your entire Claude history.")
                }
                Spacer()
                Button(action: { Task { await load() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Re-aggregate from the local DB and rescan claude's session history")
            }
            HStack(spacing: 12) {
                Text("Atelier rows use exact `total_cost_usd`; history rows estimate from token counts × published rates. On Pro/Max this is the **API-equivalent** cost — you actually pay the flat subscription.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer(minLength: 8)
                if atelierTracked > 0 || historyTracked > 0 {
                    HStack(spacing: 8) {
                        provenancePill(count: atelierTracked, label: "Atelier", color: Color.atelierAccent)
                        provenancePill(count: historyTracked, label: "History", color: Color.atelierInkSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            AtelierDivider()
        }
    }

    private func provenancePill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(AtelierFont.captionMono.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Text(label)
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    private var loadingState: some View {
        VStack { Spacer(); ProgressView(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 76, height: 76)
                Image(systemName: "chart.bar")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.atelierAccent)
            }
            VStack(spacing: 4) {
                Text("No usage yet")
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                Text("Spawn a worker and come back — Atelier records every run's cost + tokens here.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                budgetBanner
                planLimitsCard
                dataNotesCard
                // Fixed column counts so the cards never reflow into a ragged
                // 3+1. Stats span the top (4 across); the richer window cards
                // (2×2) sit left of the heatmap, which roughly matches their height.
                summaryStatsRow
                HStack(alignment: .top, spacing: 16) {
                    windowsRow
                        .frame(maxWidth: .infinity, alignment: .top)
                    heatmapCard
                        .frame(width: 420)
                }
                chartCard
                HStack(alignment: .top, spacing: 16) {
                    dayOfWeekCard
                    hourOfDayCard
                }
                projectBreakdownCard
                modelBreakdownCard
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    // MARK: Aggregations

    private struct Window: Identifiable {
        let id: String
        let label: String
        let records: [UsageRecord]
        var cost: Double { records.reduce(0) { $0 + $1.costUsd } }
        var count: Int { Set(records.compactMap { $0.sessionId }).count }
        var inputTokens: Int { records.reduce(0) { $0 + $1.inputTokens } }
        var outputTokens: Int { records.reduce(0) { $0 + $1.outputTokens } }
        var cacheReadTokens: Int { records.reduce(0) { $0 + $1.cacheReadTokens } }
        var cacheCreationTokens: Int { records.reduce(0) { $0 + $1.cacheCreationTokens } }
        var topModel: (model: String, count: Int)? {
            let counts = Dictionary(grouping: records, by: { $0.model }).mapValues { $0.count }
            return counts.max(by: { $0.value < $1.value }).map { ($0.key, $0.value) }
        }
    }

    /// Distinct sessions across all records (records are now per-message).
    private var totalSessions: Int { Set(records.compactMap { $0.sessionId }).count }

    private func windowRecords(sinceHoursAgo hours: Int) -> [UsageRecord] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return records.filter { $0.startedAt >= cutoff }
    }

    private var last24h: Window {
        Window(id: "24h", label: "Last 24h", records: windowRecords(sinceHoursAgo: 24))
    }
    private var last7d: Window {
        Window(id: "7d", label: "Last 7 days", records: windowRecords(sinceHoursAgo: 24 * 7))
    }
    private var last30d: Window {
        Window(id: "30d", label: "Last 30 days", records: windowRecords(sinceHoursAgo: 24 * 30))
    }
    private var allTime: Window {
        Window(id: "all", label: "All recorded", records: records)
    }

    // MARK: Cards

    private var windowsRow: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            alignment: .leading, spacing: 14
        ) {
            ForEach([last24h, last7d, last30d, allTime]) { w in
                windowCard(w)
            }
        }
    }

    private func windowCard(_ w: Window) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(w.label.uppercased())
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Text(String(format: "$%.4f", w.cost))
                .font(.system(.title, design: .serif).weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            HStack(spacing: 6) {
                Text("\(w.count) session\(w.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                if let top = w.topModel {
                    Text("·")
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
                    Text(modelShortName(top.model))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                    Text("×\(top.count)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            Divider().background(Color.atelierDivider.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                tokenRow("in",     count: w.inputTokens, accent: Color.atelierInk)
                tokenRow("out",    count: w.outputTokens, accent: Color.atelierAccent)
                tokenRow("cache",  count: w.cacheReadTokens + w.cacheCreationTokens,
                         accent: Color.atelierInkSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func tokenRow(_ label: String, count: Int, accent: Color) -> some View {
        HStack {
            Text(label)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
                .frame(width: 36, alignment: .leading)
            Text(formatTokenCount(count))
                .font(AtelierFont.captionMono.weight(.semibold))
                .foregroundStyle(accent)
            Spacer()
        }
    }

    // MARK: Chart

    private struct DayBucket: Identifiable {
        let day: Date
        var cost: Double
        var id: Date { day }
    }

    private var dailyBuckets: [DayBucket] {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-29 * 86400))
        var buckets: [Date: Double] = [:]
        for r in records {
            let day = cal.startOfDay(for: r.startedAt)
            if day < cutoff { continue }
            buckets[day, default: 0] += r.costUsd
        }
        // Fill missing days with 0 so the chart x-axis is continuous.
        var out: [DayBucket] = []
        var cursor = cutoff
        let today = cal.startOfDay(for: Date())
        while cursor <= today {
            out.append(DayBucket(day: cursor, cost: buckets[cursor] ?? 0))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? today
        }
        return out
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DAILY COST · LAST 30 DAYS")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Chart(dailyBuckets) { b in
                BarMark(
                    x: .value("Day", b.day, unit: .day),
                    y: .value("Cost", b.cost)
                )
                .foregroundStyle(Color.atelierAccent.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.atelierDivider.opacity(0.3))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(AtelierFont.captionMono)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.atelierDivider.opacity(0.3))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(String(format: "$%.2f", raw))
                                .font(AtelierFont.captionMono)
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    // MARK: Model breakdown

    private struct ModelRow: Identifiable {
        let model: String
        let records: [UsageRecord]
        var id: String { model }
        var cost: Double { records.reduce(0) { $0 + $1.costUsd } }
        var count: Int { Set(records.compactMap { $0.sessionId }).count }
        var tokens: Int {
            records.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
        }
    }

    private var modelRows: [ModelRow] {
        Dictionary(grouping: records, by: { $0.model })
            .map { ModelRow(model: $0.key, records: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    private var modelBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BY MODEL · ALL-TIME")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Text(String(format: "$%.4f total", allTime.cost))
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
            }
            ForEach(modelRows) { row in
                modelRowView(row, of: allTime.cost)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func modelRowView(_ row: ModelRow, of total: Double) -> some View {
        let pct = total > 0 ? row.cost / total : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(modelShortName(row.model))
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Text("·")
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
                Text("\(row.count) run\(row.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Text("\(formatTokenCount(row.tokens)) tok")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(String(format: "%.0f%%", pct * 100))
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(String(format: "$%.4f", row.cost))
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.atelierDivider.opacity(0.4))
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.atelierAccent)
                        .frame(width: max(2, proxy.size.width * pct), height: 4)
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: Helpers

    private func load() async {
        loading = true
        async let atelierAgents = (try? await store.allAgents()) ?? []
        async let historyScan = ClaudeHistoryScanner.scan()
        let agents = await atelierAgents
        let history = await historyScan
        // Plan limits are opt-in (they touch the Keychain) — only fetch once the
        // user has consented via the card's "Show my plan limits" button.
        if limitsOptIn { await loadLimits() }

        // Build taskId → project map so we can label Atelier rows by project.
        var projectByTask: [String: Project] = [:]
        let allProjects = store.projectsByWorkspace.values.flatMap { $0 }
        for project in allProjects {
            for task in store.tasks(in: project.id) {
                projectByTask[task.id] = project
            }
        }

        let atelierRecords: [UsageRecord] = agents.compactMap { a in
            guard let started = a.startedAt else { return nil }
            let project = projectByTask[a.taskId]
            return UsageRecord(
                id: a.id,
                sessionId: a.sessionId,
                model: a.model,
                costUsd: a.costUsd,
                inputTokens: a.inputTokens,
                outputTokens: a.outputTokens,
                cacheReadTokens: a.cacheReadTokens,
                cacheCreationTokens: a.cacheCreationTokens,
                startedAt: started,
                source: .atelier,
                projectKey: project?.id ?? "atelier:unknown",
                projectDisplay: project?.name ?? "(unknown project)"
            )
        }
        // Dedupe: if a session is in both lists, Atelier's record wins.
        let atelierSessionIds = Set(atelierRecords.compactMap { $0.sessionId })
        let historyFiltered = history.filter { record in
            guard let sid = record.sessionId else { return true }
            return !atelierSessionIds.contains(sid)
        }
        let merged = (atelierRecords + historyFiltered)
            .sorted { $0.startedAt > $1.startedAt }

        records = merged
        atelierTracked = atelierRecords.count
        historyTracked = Set(historyFiltered.compactMap { $0.sessionId }).count
        loading = false
    }

    private func loadLimits() async {
        limitsLoading = true
        do {
            limits = try await UsageLimitsService.fetch()
            limitsError = nil
        } catch {
            limits = nil
            limitsError = error.localizedDescription
        }
        limitsLoading = false
    }

    private func modelShortName(_ raw: String) -> String {
        switch raw {
        case "claude-opus-4-7": return "Opus 4.7"
        case "claude-opus-4-6": return "Opus 4.6"
        case "claude-sonnet-4-6": return "Sonnet 4.6"
        case "claude-haiku-4-5-20251001", "claude-haiku-4-5": return "Haiku 4.5"
        default: return raw
        }
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Summary stats row (streak + today)

    private var todaysCost: Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return records
            .filter { $0.startedAt >= start }
            .reduce(0) { $0 + $1.costUsd }
    }

    /// Days set: every day (00:00 UTC normalised) that has at least one
    /// non-zero record.
    private var activeDays: Set<Date> {
        let cal = Calendar.current
        var out = Set<Date>()
        for r in records where r.costUsd > 0 {
            out.insert(cal.startOfDay(for: r.startedAt))
        }
        return out
    }

    /// Current streak = consecutive days ending today (or yesterday) with
    /// at least one active session.
    private var currentStreak: Int {
        let cal = Calendar.current
        let days = activeDays
        var streak = 0
        var cursor = cal.startOfDay(for: Date())
        // Allow a one-day grace: if today has nothing yet, start from yesterday.
        if !days.contains(cursor),
           let y = cal.date(byAdding: .day, value: -1, to: cursor) {
            cursor = y
        }
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Longest streak = max run of consecutive active days anywhere in history.
    private var longestStreak: Int {
        let cal = Calendar.current
        let sortedDays = activeDays.sorted()
        guard !sortedDays.isEmpty else { return 0 }
        var best = 1
        var current = 1
        for i in 1..<sortedDays.count {
            let prev = sortedDays[i - 1]
            let next = sortedDays[i]
            if cal.isDate(next, inSameDayAs: cal.date(byAdding: .day, value: 1, to: prev) ?? prev) {
                current += 1
                best = max(best, current)
            } else {
                current = 1
            }
        }
        return best
    }

    private var summaryStatsRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
            alignment: .leading, spacing: 14
        ) {
            summaryStatCard(
                label: "TODAY",
                value: String(format: "$%.4f", todaysCost),
                detail: dailyBudgetUsd > 0
                    ? "budget \(String(format: "$%.2f", dailyBudgetUsd))"
                    : "no budget set",
                accent: todaysCost > dailyBudgetUsd && dailyBudgetUsd > 0
                    ? Palette.warning : Color.atelierAccent,
                icon: "calendar"
            )
            summaryStatCard(
                label: "CURRENT STREAK",
                value: "\(currentStreak)d",
                detail: currentStreak == 0 ? "go bother claude" : "consecutive day\(currentStreak == 1 ? "" : "s")",
                accent: Color.atelierAccent,
                icon: "flame.fill"
            )
            summaryStatCard(
                label: "LONGEST STREAK",
                value: "\(longestStreak)d",
                detail: "personal best",
                accent: Color.atelierAccent.opacity(0.6),
                icon: "trophy.fill"
            )
            summaryStatCard(
                label: "ACTIVE DAYS",
                value: "\(activeDays.count)",
                detail: "days touched",
                accent: Color.atelierInkSecondary,
                icon: "circle.grid.3x3.fill"
            )
        }
    }

    private func summaryStatCard(label: String,
                                 value: String,
                                 detail: String,
                                 accent: Color,
                                 icon: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(value)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Text(detail)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    @ViewBuilder
    private var budgetBanner: some View {
        if dailyBudgetUsd > 0 && todaysCost > dailyBudgetUsd {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily budget exceeded")
                        .font(AtelierFont.callout.weight(.semibold))
                        .foregroundStyle(Color.atelierInk)
                    Text("Today: \(String(format: "$%.4f", todaysCost)) · budget: \(String(format: "$%.2f", dailyBudgetUsd))")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer()
                Text("Adjust in Settings → Alerts")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .padding(14)
            .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Palette.warning.opacity(0.5), lineWidth: 1))
        }
    }

    // MARK: - Plan limits (subscription)

    private var planLimitsWindows: [(label: String, window: UsageLimitsService.Window)] {
        guard let limits else { return [] }
        var out: [(String, UsageLimitsService.Window)] = []
        if let w = limits.fiveHour { out.append(("5-hour limit", w)) }
        if let w = limits.sevenDay { out.append(("Weekly · all models", w)) }
        if let w = limits.sevenDayOpus { out.append(("Weekly · Opus", w)) }
        if let w = limits.sevenDaySonnet { out.append(("Weekly · Sonnet", w)) }
        return out
    }

    @ViewBuilder
    private var planLimitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PLAN LIMITS")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if let sub = limits?.subscriptionType, !sub.isEmpty {
                    Text(sub.uppercased())
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
                }
                Spacer()
                if limits != nil {
                    Text("subscription · live")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                }
            }
            planLimitsBody
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    @ViewBuilder
    private var planLimitsBody: some View {
        if !limitsOptIn {
            // Consent first — explain WHY before we ever touch the Keychain.
            VStack(alignment: .leading, spacing: 10) {
                Text("Show your real 5-hour and weekly subscription usage — the same numbers as Claude Code's `/usage`. Atelier reads Claude Code's saved login from your Keychain to call Anthropic's usage endpoint. macOS will ask once to allow access — click “Always Allow”. Read-only; nothing is stored or sent anywhere else.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    limitsOptIn = true
                    Task { await loadLimits() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.open").font(.system(size: 11))
                        Text("Show my plan limits").fontWeight(.semibold)
                    }
                    .foregroundStyle(Color.atelierAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else if limitsLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your plan limits…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .padding(.vertical, 4)
        } else if !planLimitsWindows.isEmpty {
            ForEach(Array(planLimitsWindows.enumerated()), id: \.offset) { _, item in
                limitWindowRow(label: item.label, window: item.window)
            }
            Text("Real subscription utilization from Claude — separate from the API-equivalent $ below.")
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(limitsError ?? "Subscription limits unavailable.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Retry") { Task { await loadLimits() } }
                    .font(AtelierFont.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.atelierAccent)
            }
            .padding(.vertical, 4)
        }
    }

    private func limitWindowRow(label: String, window: UsageLimitsService.Window) -> some View {
        let pct = max(0, min(1, window.utilization / 100))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                if let reset = window.resetsAt {
                    Text("· resets \(reset.formatted(.relative(presentation: .named)))")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                }
                Spacer()
                Text(String(format: "%.0f%%", window.utilization))
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(limitColor(window.utilization))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.atelierDivider.opacity(0.4)).frame(height: 4)
                    Rectangle().fill(limitColor(window.utilization))
                        .frame(width: max(2, proxy.size.width * pct), height: 4)
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }

    private func limitColor(_ utilization: Double) -> Color {
        if utilization >= 90 { return Palette.error }
        if utilization >= 70 { return Palette.warning }
        return Color.atelierAccent
    }

    // MARK: - Data provenance & limitations

    /// Span of the local session history we could actually read.
    private var coverageText: String {
        let history = records.filter { $0.source == .history }.map(\.startedAt)
        guard let lo = history.min(), let hi = history.max() else { return "no local session logs found" }
        let cal = Calendar.current
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: lo), to: cal.startOfDay(for: hi)).day ?? 0) + 1
        let f = DateFormatter(); f.dateStyle = .medium
        return "\(f.string(from: lo)) → \(f.string(from: hi)) (\(days) day\(days == 1 ? "" : "s"))"
    }

    private var dataNotesCard: some View {
        DisclosureGroup(isExpanded: $dataNotesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                dataNote("Two sources",
                         "Atelier-tracked runs use the exact `total_cost_usd` reported by each `claude` run. Everything else is scanned from Claude Code's local session logs (`~/.claude/projects`), where the $ is ESTIMATED from token counts × Anthropic's published rates.")
                dataNote("History is capped by Claude Code",
                         "Claude Code prunes old session logs (`cleanupPeriodDays`), so the dashboard only sees days that still have logs on disk — older usage is gone and can't be recovered. Your local history currently covers \(coverageText).")
                dataNote("$ is API-equivalent",
                         "On Pro / Max / Team you pay a flat subscription. The $ shown is what the same tokens would cost on the pay-as-you-go API — useful for relative comparison, not your actual bill.")
                dataNote("Plan limits are live & real",
                         "The PLAN LIMITS card is fetched live from your subscription (real 5-hour / weekly %), independent of the estimated $ below.")
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.atelierInkSecondary)
                Text("Where these numbers come from")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider.opacity(0.7), lineWidth: 1))
    }

    private func dataNote(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AtelierFont.caption.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Text(LocalizedStringKey(body))   // render inline `code` / **bold** markdown
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .tint(Color.atelierAccent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - GitHub-style heatmap (last ~10 weeks)

    /// Claude Code prunes old session logs, so a 52-week grid is ~85% empty.
    /// A 10-week window (~70 days) fills the card with the data that actually exists.
    private static let heatmapWeeks = 10

    private struct HeatmapDay: Identifiable, Hashable {
        let date: Date
        let cost: Double
        var id: Date { date }
    }

    private var heatmapDays: [HeatmapDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weeksBack = Self.heatmapWeeks - 1
        let anchor = cal.date(byAdding: .weekOfYear, value: -weeksBack, to: today) ?? today
        // Move to start of that week (Sunday).
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchor)
        let weekStart = cal.date(from: comps) ?? anchor

        var buckets: [Date: Double] = [:]
        for r in records {
            let day = cal.startOfDay(for: r.startedAt)
            if day < weekStart { continue }
            buckets[day, default: 0] += r.costUsd
        }
        var out: [HeatmapDay] = []
        var cursor = weekStart
        while cursor <= today {
            out.append(HeatmapDay(date: cursor, cost: buckets[cursor] ?? 0))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? today
        }
        return out
    }

    private var heatmapThresholds: [Double] {
        // 4 buckets above zero (level 1-4). Quartiles of non-zero days.
        let nonZero = heatmapDays.map(\.cost).filter { $0 > 0 }.sorted()
        if nonZero.isEmpty { return [0, 0, 0, 0] }
        let q1 = nonZero[Int(Double(nonZero.count) * 0.25)]
        let q2 = nonZero[Int(Double(nonZero.count) * 0.50)]
        let q3 = nonZero[Int(Double(nonZero.count) * 0.75)]
        let q4 = nonZero.last ?? 0
        return [q1, q2, q3, q4]
    }

    private func heatmapLevel(for cost: Double) -> Int {
        if cost <= 0 { return 0 }
        let t = heatmapThresholds
        if cost <= t[0] { return 1 }
        if cost <= t[1] { return 2 }
        if cost <= t[2] { return 3 }
        return 4
    }

    private func heatmapColor(level: Int) -> Color {
        switch level {
        case 0: return Color.atelierDivider.opacity(0.3)
        case 1: return Color.atelierAccent.opacity(0.30)
        case 2: return Color.atelierAccent.opacity(0.55)
        case 3: return Color.atelierAccent.opacity(0.80)
        default: return Color.atelierAccent
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DAILY ACTIVITY · LAST \(Self.heatmapWeeks) WEEKS")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                HStack(spacing: 6) {
                    Text("less").font(AtelierFont.captionMono).foregroundStyle(Color.atelierInkSecondary)
                    ForEach(0...4, id: \.self) { lvl in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatmapColor(level: lvl))
                            .frame(width: 10, height: 10)
                    }
                    Text("more").font(AtelierFont.captionMono).foregroundStyle(Color.atelierInkSecondary)
                }
            }
            heatmapGrid
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var heatmapGrid: some View {
        let days = heatmapDays
        // Group into weeks (7 days per column). Pad the leading week so day 0
        // sits on its real day-of-week row.
        let cal = Calendar.current
        let leadOffset = max(0, (cal.component(.weekday, from: days.first?.date ?? Date()) - 1))
        var padded: [HeatmapDay?] = Array(repeating: nil, count: leadOffset) + days.map { Optional($0) }
        while padded.count % 7 != 0 { padded.append(nil) }
        let weeks: [[HeatmapDay?]] = stride(from: 0, to: padded.count, by: 7).map {
            Array(padded[$0..<min($0 + 7, padded.count)])
        }
        let cell: CGFloat = 22
        let gap: CGFloat = 5
        let weekdayNames = ["", "Mon", "", "Wed", "", "Fri", ""]   // index = weekday-1 (Sun=0)
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(0..<7, id: \.self) { i in
                    Text(weekdayNames[i])
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                        .frame(width: 30, height: cell, alignment: .trailing)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { dayIdx in
                        heatmapCell(day: week.indices.contains(dayIdx) ? week[dayIdx] : nil, size: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func heatmapCell(day: HeatmapDay?, size: CGFloat) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 5)
                .fill(heatmapColor(level: heatmapLevel(for: day.cost)))
                .frame(width: size, height: size)
                .help(heatmapTooltip(day))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.clear)
                .frame(width: size, height: size)
        }
    }

    private func heatmapTooltip(_ day: HeatmapDay) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        if day.cost == 0 {
            return "\(df.string(from: day.date)) — no activity"
        }
        return "\(df.string(from: day.date)) — \(String(format: "$%.4f", day.cost))"
    }

    // MARK: - Day-of-week + hour-of-day

    private struct WeekdayBucket: Identifiable {
        let weekday: Int       // 1 = Sunday … 7 = Saturday (Calendar convention)
        let cost: Double
        let count: Int
        var id: Int { weekday }
        var label: String {
            // Monday-start order in the UI; map back via shortLabel.
            let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return labels[(weekday - 1) % 7]
        }
    }

    private var weekdayBuckets: [WeekdayBucket] {
        let cal = Calendar.current
        var cost = [Int: Double]()
        var count = [Int: Int]()
        for r in records {
            let wd = cal.component(.weekday, from: r.startedAt)
            cost[wd, default: 0] += r.costUsd
            count[wd, default: 0] += 1
        }
        // Reorder: start Monday for European readability.
        let order = [2, 3, 4, 5, 6, 7, 1]
        return order.map { WeekdayBucket(weekday: $0, cost: cost[$0] ?? 0, count: count[$0] ?? 0) }
    }

    private var dayOfWeekCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY DAY OF WEEK")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Chart(weekdayBuckets) { b in
                BarMark(
                    x: .value("Day", b.label),
                    y: .value("Cost", b.cost)
                )
                .foregroundStyle(Color.atelierAccent.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel().font(AtelierFont.captionMono)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.atelierDivider.opacity(0.3))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(String(format: "$%.0f", raw)).font(AtelierFont.captionMono)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private struct HourBucket: Identifiable {
        let hour: Int
        let cost: Double
        var id: Int { hour }
    }

    private var hourBuckets: [HourBucket] {
        let cal = Calendar.current
        var cost = [Int: Double]()
        for r in records {
            let h = cal.component(.hour, from: r.startedAt)
            cost[h, default: 0] += r.costUsd
        }
        return (0..<24).map { HourBucket(hour: $0, cost: cost[$0] ?? 0) }
    }

    private var hourOfDayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY HOUR OF DAY · LOCAL")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Chart(hourBuckets) { b in
                BarMark(
                    x: .value("Hour", b.hour),
                    y: .value("Cost", b.cost)
                )
                .foregroundStyle(Color.atelierAccent.gradient)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) {
                            Text(String(format: "%02d:00", h)).font(AtelierFont.captionMono)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.atelierDivider.opacity(0.3))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(String(format: "$%.0f", raw)).font(AtelierFont.captionMono)
                        }
                    }
                }
            }
            .frame(height: 160)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    // MARK: - Project breakdown

    private struct ProjectRow: Identifiable {
        let projectKey: String
        let display: String
        let records: [UsageRecord]
        var id: String { projectKey }
        var cost: Double { records.reduce(0) { $0 + $1.costUsd } }
        var count: Int { Set(records.compactMap { $0.sessionId }).count }
        var tokens: Int {
            records.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
        }
        var lastTouched: Date? { records.map(\.startedAt).max() }
    }

    private var projectRows: [ProjectRow] {
        Dictionary(grouping: records, by: { $0.projectKey })
            .map { key, list in
                ProjectRow(projectKey: key,
                           display: list.first?.projectDisplay ?? key,
                           records: list)
            }
            .sorted { $0.cost > $1.cost }
    }

    private var projectBreakdownCard: some View {
        let rows = Array(projectRows.prefix(10))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TOP PROJECTS · ALL-TIME")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                if projectRows.count > 10 {
                    Text("(top 10 of \(projectRows.count))")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            let total = allTime.cost
            ForEach(rows) { row in
                projectRowView(row, of: total)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func projectRowView(_ row: ProjectRow, of total: Double) -> some View {
        let pct = total > 0 ? row.cost / total : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.display)
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·").foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
                Text("\(row.count) session\(row.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                if let last = row.lastTouched {
                    Text("· last \(last.formatted(.relative(presentation: .named)))")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                }
                Spacer()
                Text("\(formatTokenCount(row.tokens)) tok")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(String(format: "%.0f%%", pct * 100))
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(String(format: "$%.4f", row.cost))
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.atelierDivider.opacity(0.4)).frame(height: 4)
                    Rectangle().fill(Color.atelierAccent)
                        .frame(width: max(2, proxy.size.width * pct), height: 4)
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
    }
}
