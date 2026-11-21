import WidgetKit
import SwiftUI
import ActivityKit
import MolaActivity

// 实时活动扩展（xtool.yml `extensions` → PlugIns/MolaWidgets.appex，扩展点 com.apple.widgetkit-extension）。

/// 入口：Package.swift 用 `-e _MolaWidgetsMain` 指定（xtool 默认 `_NSExtensionMain` 会让 @main 与整个 Widget 被死代码剔除）。
/// 与 Xcode 生成的 Widget 扩展一致：由 WidgetBundle.main() 启动。
@_cdecl("MolaWidgetsMain")
public func molaWidgetsMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    MainActor.assumeIsolated { MolaWidgetBundle.main() }
    return 0
}

// Xcode 构建（Xcode/project.yml 定义 XCODE_BUILD）走标准 @main 入口，与 Xcode Widget 模板一致。
#if XCODE_BUILD
@main
#endif
struct MolaWidgetBundle: WidgetBundle {
    var body: some Widget {
        MolaLiveActivity()
    }
}

private let accent = Color(red: 0xBE / 255, green: 0x72 / 255, blue: 0x7F / 255)

struct MolaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MolaActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(accent)
                .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            let a = context.attributes
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Glyph(phase: s.phase, size: 28)
                        Text(a.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusTime(state: s).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(a.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(s.phase.label, systemImage: s.phase.symbol)
                            .font(.caption.weight(.medium)).foregroundStyle(phaseColor(s.phase))
                        if !s.snippet.isEmpty {
                            Text(s.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Glyph(phase: s.phase, size: 20)
            } compactTrailing: {
                if s.phase.isRunning {
                    Text(timerInterval: s.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit()).foregroundStyle(accent)
                        .frame(maxWidth: 40)
                } else {
                    Image(systemName: s.phase.symbol).foregroundStyle(phaseColor(s.phase))
                }
            } minimal: {
                Glyph(phase: s.phase, size: 20)
            }
            .widgetURL(a.deepLink)
            .keylineTint(accent)
        }
    }
}

private func phaseColor(_ p: MolaActivityAttributes.Phase) -> Color {
    switch p {
    case .done: .green
    case .failed: .orange
    case .stopped: .secondary
    default: accent
    }
}

/// 运行中：品牌色圆底 + 闪烁的 sparkles；结束后换成状态图标。
private struct Glyph: View {
    let phase: MolaActivityAttributes.Phase
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(phase.isRunning ? accent : phaseColor(phase).opacity(0.25))
            Image(systemName: phase.isRunning ? (phase == .imaging ? "paintbrush.pointed.fill" : "sparkles") : phase.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(phase.isRunning ? .white : phaseColor(phase))
                .symbolEffect(.pulse, isActive: phase.isRunning)
        }
        .frame(width: size, height: size)
    }
}

/// 运行中显示计时，结束后显示用时。
private struct StatusTime: View {
    let state: MolaActivityAttributes.ContentState

    var body: some View {
        if state.phase.isRunning {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        } else if let end = state.endedAt {
            Text(Self.duration(end.timeIntervalSince(state.startedAt)))
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(Int(t.rounded()), 0)
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
}

private struct LockScreenView: View {
    let attributes: MolaActivityAttributes
    let state: MolaActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Glyph(phase: state.phase, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    StatusTime(state: state).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(state.phase.label).foregroundStyle(phaseColor(state.phase))
                    Text("·").foregroundStyle(.tertiary)
                    Text(attributes.model).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption.weight(.medium))
                if !state.snippet.isEmpty {
                    Text(state.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }
}
