import SwiftUI

/// 阅读统计仪表盘（本周阅读时长 / 本周翻阅页数 / 连续阅读纪录 + 近 7 日趋势 + 累计）
struct ReadingStatsDashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AppStore

    @State private var chartMetric: ChartMetric = .duration
    @State private var showResetConfirm = false

    enum ChartMetric: String, CaseIterable, Identifiable {
        case duration
        case pages

        var id: String { rawValue }

        var title: String {
            switch self {
            case .duration: return "时长"
            case .pages: return "页数"
            }
        }
    }

    private var summary: ReadingStatsSummary {
        store.readingStatsSummary()
    }

    var body: some View {
        let data = summary
        VStack(alignment: .leading, spacing: 12) {
            headerRow(data)
            statCards(data)
            trendCard(data)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .alert(isPresented: $showResetConfirm) {
            Alert(
                title: Text("清空阅读统计？"),
                message: Text("将清除全部阅读时长、翻阅页数与连续打卡记录，阅读进度不受影响。"),
                primaryButton: .destructive(Text("清空")) {
                    store.resetReadingStats()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - Header

    private func headerRow(_ summary: ReadingStatsSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("阅读统计")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("本周已读 \(Self.longDurationText(summary.weekSeconds))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Menu {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("清空阅读统计", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Stat Cards

    private func statCards(_ summary: ReadingStatsSummary) -> some View {
        HStack(spacing: 8) {
            ReadingStatCard(
                value: Self.compactDurationText(summary.weekSeconds),
                label: "本周阅读时长",
                tint: .accentColor
            )
            ReadingStatCard(
                value: "\(summary.weekPages)",
                label: "本周翻阅页数",
                tint: .primary
            )
            ReadingStatCard(
                value: "\(summary.streakDays) 天",
                label: "连续阅读纪录",
                tint: .green
            )
        }
    }

    // MARK: - Trend

    private func trendCard(_ summary: ReadingStatsSummary) -> some View {
        let values: [Double] = summary.recentDays.map { day in
            chartMetric == .duration ? day.seconds : Double(day.pages)
        }
        let maxValue = max(values.max() ?? 0, chartMetric == .duration ? 600 : 10)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("近 7 日")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Picker("统计维度", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(summary.recentDays.enumerated()), id: \.element.id) { idx, day in
                    let value = values[idx]
                    VStack(spacing: 5) {
                        Text(value > 0 ? barValueText(day) : " ")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(day.isToday ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        GeometryReader { geo in
                            let ratio = maxValue > 0 ? value / maxValue : 0
                            let height = value > 0 ? max(4, geo.size.height * CGFloat(min(1, ratio))) : 3
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(barFill(isToday: day.isToday, hasValue: value > 0))
                                    .frame(height: height)
                            }
                        }
                        .frame(height: 72)

                        Text(day.label)
                            .font(.system(size: 10.5, weight: day.isToday ? .bold : .medium))
                            .foregroundStyle(day.isToday ? Color.accentColor : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: chartMetric)

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("累计沉浸阅读 \(Self.longDurationText(summary.totalSeconds)) · 翻阅 \(summary.totalPages) 页")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
        )
    }

    private func barValueText(_ day: ReadingStatsDayPoint) -> String {
        switch chartMetric {
        case .duration: return Self.compactDurationText(day.seconds)
        case .pages: return "\(day.pages)"
        }
    }

    private func barFill(isToday: Bool, hasValue: Bool) -> Color {
        guard hasValue else { return Color.primary.opacity(0.08) }
        return isToday ? Color.accentColor : Color.accentColor.opacity(0.45)
    }

    // MARK: - Formatting

    /// 紧凑时长：< 1 小时显示「35m」，否则显示「4.2h」
    static func compactDurationText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = seconds / 3600
        return hours >= 100 ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    /// 完整时长：「12 分钟」/「4 小时 12 分」
    static func longDurationText(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 {
            return "\(totalMinutes) 分钟"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
    }
}

/// 单个统计卡片
private struct ReadingStatCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 0.5)
        )
    }
}
