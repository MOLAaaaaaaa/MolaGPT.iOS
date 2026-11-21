import Foundation
import MolaCore

/// 画图工作台表（image_tasks / image_runs / image_versions）。
extension MolaStore {
    public func imageTasks() -> [ImageTask] {
        (try? db.query("SELECT task_id,title,provider_id,model_id,mode,pinned,created_at,updated_at FROM image_tasks WHERE deleted_at IS NULL ORDER BY pinned DESC, updated_at DESC") { r in
            var t = ImageTask(id: r.string(0), title: r.string(1), providerId: r.stringOrNil(2), modelId: r.stringOrNil(3),
                              mode: WorkbenchMode(rawValue: r.string(4)) ?? .chat, pinned: r.bool(5), createdAt: r.int64(6))
            t.updatedAt = r.int64(7)
            return t
        }) ?? []
    }

    public func upsert(_ t: ImageTask) throws {
        try db.run("""
            INSERT INTO image_tasks (task_id,title,provider_id,model_id,mode,pinned,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(task_id) DO UPDATE SET title=excluded.title, provider_id=excluded.provider_id, model_id=excluded.model_id,
              mode=excluded.mode, pinned=excluded.pinned, updated_at=excluded.updated_at
            """, [.text(t.id), .text(t.title), .of(t.providerId), .of(t.modelId), .text(t.mode.rawValue), .of(t.pinned), .of(t.createdAt), .of(t.updatedAt)])
    }

    public func deleteImageTask(_ id: String) throws {
        try db.transaction {
            try db.run("DELETE FROM image_versions WHERE task_id = ?", [.text(id)])
            try db.run("DELETE FROM image_runs WHERE task_id = ?", [.text(id)])
            try db.run("DELETE FROM image_tasks WHERE task_id = ?", [.text(id)])
        }
    }

    public func imageRuns(_ taskId: String) -> [ImageRun] {
        (try? db.query("SELECT id,task_id,prompt,kind,provider_id,model_id,size,count,params_json,refs_json,active_version_id,created_at FROM image_runs WHERE task_id = ? ORDER BY created_at", [.text(taskId)]) { r in
            var run = ImageRun(id: r.string(0), taskId: r.string(1), prompt: r.string(2), kind: RunKind(rawValue: r.string(3)) ?? .new,
                               providerId: r.stringOrNil(4), modelId: r.stringOrNil(5), size: r.string(6), count: r.int(7),
                               params: decodeJSON(ImageParams.self, r.stringOrNil(8)) ?? ImageParams(), refs: decodeJSON([ImageRef].self, r.stringOrNil(9)) ?? [],
                               createdAt: r.int64(11))
            run.activeVersionId = r.stringOrNil(10)
            return run
        }) ?? []
    }

    public func upsert(_ run: ImageRun) throws {
        try db.run("INSERT OR REPLACE INTO image_runs (id,task_id,prompt,kind,provider_id,model_id,size,count,params_json,refs_json,active_version_id,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   [.text(run.id), .text(run.taskId), .text(run.prompt), .text(run.kind.rawValue), .of(run.providerId), .of(run.modelId), .text(run.size),
                    .of(run.count), .json(run.params), .json(run.refs), .of(run.activeVersionId), .of(run.createdAt)])
    }

    public func imageVersions(task taskId: String) -> [ImageVersion] {
        (try? db.query("SELECT id,run_id,task_id,status,started_at,ended_at,outputs_json,error FROM image_versions WHERE task_id = ? ORDER BY created_at", [.text(taskId)], map: Self.version)) ?? []
    }

    public func allSuccessVersions() -> [ImageVersion] {
        (try? db.query("SELECT id,run_id,task_id,status,started_at,ended_at,outputs_json,error FROM image_versions WHERE status = 'success' ORDER BY ended_at DESC", map: Self.version)) ?? []
    }

    private static func version(_ r: SQLiteDB.Row) -> ImageVersion {
        var v = ImageVersion(id: r.string(0), runId: r.string(1), taskId: r.string(2), status: VersionStatus(rawValue: r.string(3)) ?? .failed, startedAt: r.int64(4))
        v.endedAt = r.isNull(5) ? nil : r.int64(5)
        v.outputs = decodeJSON([ImageOutput].self, r.stringOrNil(6)) ?? []
        v.error = r.stringOrNil(7)
        return v
    }

    public func upsert(_ v: ImageVersion) throws {
        try db.run("INSERT OR REPLACE INTO image_versions (id,run_id,task_id,status,started_at,ended_at,outputs_json,error,created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                   [.text(v.id), .text(v.runId), .text(v.taskId), .text(v.status.rawValue), .of(v.startedAt), v.endedAt.map { .of($0) } ?? .null,
                    .json(v.outputs), .of(v.error), .of(v.startedAt)])
    }

    /// 启动对账：上次遗留的 running 标为失败。
    public func failStaleImageVersions() throws {
        try db.run("UPDATE image_versions SET status = 'failed', error = '应用退出，生成已中断', ended_at = ? WHERE status = 'running'", [.of(IDs.nowMs())])
    }
}
