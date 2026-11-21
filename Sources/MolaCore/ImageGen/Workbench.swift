import Foundation

// 画图工作台（对应安卓 feature/imagegen：ImageTaskModels / WorkbenchPlan）。

public enum WorkbenchMode: String, Codable, Sendable, CaseIterable {
    case chat, gen
    public var label: String { self == .chat ? "续改" : "新图" }
}

/// 轮类型：new 生成新图；chain 续改上一张；base 单参考图编辑；refs 多参考图；per_image 逐张编辑。
public enum RunKind: String, Codable, Sendable { case new, chain, base, refs, perImage = "per_image" }

public enum VersionStatus: String, Codable, Sendable { case running, success, failed, canceled }

public struct ImageOutput: Codable, Sendable, Hashable {
    /// `local:<相对 Documents 路径>` 或远程 URL。
    public var src: String
    public var width: Int?
    public var height: Int?
    public init(src: String, width: Int? = nil, height: Int? = nil) { self.src = src; self.width = width; self.height = height }
}

public struct ImageRef: Codable, Sendable, Hashable {
    public var src: String
    public var mask: String?
    public var fromOutput: Bool
    public init(src: String, mask: String? = nil, fromOutput: Bool = false) { self.src = src; self.mask = mask; self.fromOutput = fromOutput }
}

public struct ImageTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var providerId: String?
    public var modelId: String?
    public var mode: WorkbenchMode
    public var pinned: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(id: String = IDs.generic("imgtask"), title: String = "新的画图", providerId: String? = nil, modelId: String? = nil,
                mode: WorkbenchMode = .chat, pinned: Bool = false, createdAt: Int64 = IDs.nowMs()) {
        self.id = id; self.title = title; self.providerId = providerId; self.modelId = modelId; self.mode = mode
        self.pinned = pinned; self.createdAt = createdAt; self.updatedAt = createdAt
    }
}

public struct ImageRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var taskId: String
    public var prompt: String
    public var kind: RunKind
    public var providerId: String?
    public var modelId: String?
    public var size: String
    public var count: Int
    public var params: ImageParams
    public var refs: [ImageRef]
    public var activeVersionId: String?
    public var createdAt: Int64
    public init(id: String = IDs.generic("run"), taskId: String, prompt: String, kind: RunKind, providerId: String?, modelId: String?,
                size: String, count: Int, params: ImageParams, refs: [ImageRef], createdAt: Int64 = IDs.nowMs()) {
        self.id = id; self.taskId = taskId; self.prompt = prompt; self.kind = kind; self.providerId = providerId; self.modelId = modelId
        self.size = size; self.count = count; self.params = params; self.refs = refs; self.activeVersionId = nil; self.createdAt = createdAt
    }
}

public struct ImageVersion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var runId: String
    public var taskId: String
    public var status: VersionStatus
    public var startedAt: Int64
    public var endedAt: Int64?
    public var outputs: [ImageOutput]
    public var error: String?
    public init(id: String = IDs.generic("ver"), runId: String, taskId: String, status: VersionStatus = .running, startedAt: Int64 = IDs.nowMs()) {
        self.id = id; self.runId = runId; self.taskId = taskId; self.status = status; self.startedAt = startedAt; self.endedAt = nil
        self.outputs = []; self.error = nil
    }
}

public enum WorkbenchPlan {
    public static let sizes: [(String, String)] = [("1024x1024", "1:1"), ("1024x1536", "2:3"), ("1536x1024", "3:2"), ("2048x2048", "2K 1:1"),
                                                   ("1152x2048", "9:16"), ("2048x1152", "16:9"), ("2160x3840", "4K 竖"), ("3840x2160", "4K 横")]
    public static let counts = [1, 2, 4]

    /// 模型不支持编辑 → new；1 张参考图 → base；≥2 张 → refs（逐张编辑 → per_image）；chat 模式无图但已有结果 → chain。
    public static func kind(mode: WorkbenchMode, supportsEdit: Bool, refs: Int, perImage: Bool, hasPrevious: Bool) -> RunKind {
        guard supportsEdit else { return .new }
        if refs == 1 { return .base }
        if refs >= 2 { return perImage ? .perImage : .refs }
        if mode == .chat && hasPrevious { return .chain }
        return .new
    }

    /// 自定义尺寸：边长对齐 16，范围 256–3840。
    public static func normalize(width: Int, height: Int) -> String {
        func c(_ v: Int) -> Int { min(3840, max(256, (v / 16) * 16)) }
        return "\(c(width))x\(c(height))"
    }
}
