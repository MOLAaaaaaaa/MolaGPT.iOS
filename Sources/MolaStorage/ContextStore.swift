import Foundation
import MolaCore

/// 上下文检查点（对应安卓 context_checkpoints / context_compaction_usage）。
extension MolaStore {
    private static let ckptCols = "id,session_id,anchor_message_id,summary,covered_digest,tokens_before,tokens_after,reason,provider_id,model_id,input_tokens,output_tokens,cost_usd,stale,created_at"

    public func checkpoints(_ sessionId: String) -> [ContextCheckpoint] {
        (try? db.query("SELECT \(Self.ckptCols) FROM context_checkpoints WHERE session_id = ? ORDER BY created_at", [.text(sessionId)]) { r in
            ContextCheckpoint(id: r.string(0), sessionId: r.string(1), anchorMessageId: r.string(2), summary: r.string(3), coveredDigest: r.string(4),
                              tokensBefore: r.int(5), tokensAfter: r.int(6), reason: CompactionReason(rawValue: r.string(7)) ?? .threshold,
                              providerId: r.stringOrNil(8), modelId: r.stringOrNil(9), inputTokens: r.isNull(10) ? nil : r.int(10),
                              outputTokens: r.isNull(11) ? nil : r.int(11), costUsd: r.isNull(12) ? nil : r.double(12), stale: r.bool(13), createdAt: r.int64(14))
        }) ?? []
    }

    public func insert(_ c: ContextCheckpoint) throws {
        try db.run("INSERT OR REPLACE INTO context_checkpoints (\(Self.ckptCols)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   [.text(c.id), .text(c.sessionId), .text(c.anchorMessageId), .text(c.summary), .text(c.coveredDigest), .of(c.tokensBefore),
                    .of(c.tokensAfter), .text(c.reason.rawValue), .of(c.providerId), .of(c.modelId), c.inputTokens.map { .of($0) } ?? .null,
                    c.outputTokens.map { .of($0) } ?? .null, c.costUsd.map { .double($0) } ?? .null, .of(c.stale), .of(c.createdAt)])
    }

    public func deleteCheckpoints(_ sessionId: String) throws {
        try db.run("DELETE FROM context_checkpoints WHERE session_id = ?", [.text(sessionId)])
    }
}
