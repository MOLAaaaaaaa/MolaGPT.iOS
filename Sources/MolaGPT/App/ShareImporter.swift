import Foundation
import MolaCore

/// 接收分享扩展落盘的内容：回到前台或收到 `molagpt://share` 时调用。
/// 所有待处理条目合并进一个新对话：草稿 = 用户的话 + 文字 + 链接，文件转成附件；不自动发送，留给用户确认。
@MainActor
enum ShareImporter {
    static func consume(_ app: AppModel) {
        guard let root = ShareInbox.root() else { return }
        let pending = ShareInbox.pending(in: root)
        guard !pending.isEmpty else { return }
        app.newConversation()
        guard let c = app.current else { return }
        let draft = ShareInbox.composeDraft(pending.map(\.item))
        if !draft.isEmpty { c.draft = c.draft.isEmpty ? draft : c.draft + "\n\n" + draft }
        for (item, dir) in pending {
            for f in item.files {
                // 去掉同名去重时加的 "N_" 前缀
                let name = f.name.replacingOccurrences(of: "^[0-9]+_", with: "", options: .regularExpression)
                c.importFile(dir.appendingPathComponent(f.name), displayName: name.isEmpty ? f.name : name)
            }
            ShareInbox.remove(dir)
        }
        app.chatFocusToken += 1
    }
}
