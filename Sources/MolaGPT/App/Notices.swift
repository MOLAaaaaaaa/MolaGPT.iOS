import Foundation
import SwiftUI
import UserNotifications
import MolaCore
import MolaStorage

/// 回答完成通知（对应安卓 NotificationController）：App 不在前台、或正在看别的对话时提醒；点按打开该对话。
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    unowned let app: AppModel
    var isActive = true

    init(app: AppModel) {
        self.app = app
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func register(on planner: TurnPlanner) {
        planner.afterTurnHooks.append { [unowned self] c in self.notify(c) }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ c: ChatController) {
        guard app.settings.completionNotifications else { return }
        if isActive && app.current === c { return }
        let content = UNMutableNotificationContent()
        content.title = c.selection?.model.displayName ?? "MolaGPT"
        let t = c.conversation.title
        content.body = t == Conversation.defaultTitle ? "回复已完成" : "「\(t)」回复已完成"
        content.sound = .default
        content.userInfo = ["open_conversation_session_id": c.conversation.sessionId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "done-\(c.conversation.sessionId)", content: content, trigger: nil))
    }

    func notifyImage(taskId: String, title: String, count: Int, failed: Bool) {
        guard app.settings.completionNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "画图工作"
        content.body = failed ? "「\(title)」生成失败" : "「\(title)」已生成 \(count) 张"
        content.userInfo = ["open_image_task_id": taskId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "img-\(taskId)", content: content, trigger: nil))
    }

    // 用 completion handler 版本而非 async 版本：系统可能在后台线程回调（冷启动时尤甚），统一切回主线程再导航。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sid = info["open_conversation_session_id"] as? String
        let task = info["open_image_task_id"] as? String
        nonisolated(unsafe) let done = completionHandler   // 系统回调未标 Sendable，只在主线程调用一次
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.open(sessionId: sid, imageTask: task) }
            done()
        }
    }

    /// 点按通知：打开对应对话并切到聊天栏（iPhone 上否则可能停在对话列表），或打开画图任务。
    private func open(sessionId: String?, imageTask: String?) {
        if let sessionId {
            app.showSettings = false
            app.showImageWorkbench = false
            app.open(sessionId)
            app.chatFocusToken += 1
        }
        if let imageTask { app.openImageTask(imageTask) }
    }
}

/// 运营消息（android-messages.json，三端共用 feed）：每条按 id 只展示一次。
struct OpsMessage: Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let url: URL?
    let urlLabel: String?
}

enum StartupNotices {
    static func fetch() async -> [OpsMessage]? {
        var r = URLRequest(url: MolaEndpoints.url(MolaEndpoints.messagesFeed))
        r.setValue(MolaUA.fixed, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = JSONValue.parse(data)?["messages"]?.arrayValue else { return nil }
        return arr.compactMap { m in
            guard let id = m["id"]?.stringValue?.nonBlank, let t = m["title"]?.stringValue?.nonBlank, let b = m["body"]?.stringValue?.nonBlank else { return nil }
            return OpsMessage(id: id, title: t, body: b, url: m["url"]?.stringValue.flatMap(URL.init(string:)), urlLabel: m["urlLabel"]?.stringValue)
        }
    }
}

struct OpsMessageSheet: View {
    let message: OpsMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(message.title).font(.title2.weight(.bold))
                    MarkdownView(text: message.body)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let u = message.url {
                        Button { openURL(u); dismiss() } label: { Text(message.urlLabel ?? "查看详情").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Button("知道了") { dismiss() }.controlSize(.large)
                }
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
