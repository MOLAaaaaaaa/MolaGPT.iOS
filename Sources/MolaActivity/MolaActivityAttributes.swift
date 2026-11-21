import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// 实时活动（灵动岛 / 锁屏）的共享数据结构：主 App 发起与更新，MolaWidgets 扩展负责绘制。
// 两边必须使用同一个类型（同模块同名），所以单独成一个小 target。

public struct MolaActivityAttributes: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case chat, image }

    public enum Phase: String, Codable, Hashable, Sendable {
        case thinking, writing, tool, imaging, done, failed, stopped

        public var isRunning: Bool { self == .thinking || self == .writing || self == .tool || self == .imaging }

        public var label: String {
            switch self {
            case .thinking: "正在思考"
            case .writing: "正在回答"
            case .tool: "正在使用工具"
            case .imaging: "正在生成图片"
            case .done: "已完成"
            case .failed: "出错了"
            case .stopped: "已停止"
            }
        }

        public var symbol: String {
            switch self {
            case .thinking: "brain"
            case .writing: "text.bubble"
            case .tool: "wrench.and.screwdriver"
            case .imaging: "photo"
            case .done: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .stopped: "stop.circle.fill"
            }
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        /// 回答末尾若干字 / 工具名 / 图片提示词。
        public var snippet: String
        public var startedAt: Date
        public var endedAt: Date?

        public init(phase: Phase, snippet: String, startedAt: Date, endedAt: Date? = nil) {
            self.phase = phase; self.snippet = snippet; self.startedAt = startedAt; self.endedAt = endedAt
        }
    }

    public var kind: Kind
    /// 会话 id（点按打开 molagpt://chat/<id>）或图像任务 id。
    public var targetId: String
    public var title: String
    public var model: String

    public init(kind: Kind, targetId: String, title: String, model: String) {
        self.kind = kind; self.targetId = targetId; self.title = title; self.model = model
    }

    public var deepLink: URL {
        URL(string: kind == .chat ? "molagpt://chat/\(targetId)" : "molagpt://image/\(targetId)")!
    }
}

#if canImport(ActivityKit) && os(iOS)
extension MolaActivityAttributes: ActivityAttributes {}
#endif
