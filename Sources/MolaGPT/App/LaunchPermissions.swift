import UIKit
import AVFoundation
import Photos
import UserNotifications

/// 启动时申请权限：只申请仍未决定（notDetermined）的，逐个弹出，系统对已决定的不会再弹。
/// - 通知：回答完成 / 图片生成完成提醒（实时活动不需要额外权限）
/// - 相机：拍照作为附件
/// - 相册写入：保存生成或预览的图片（选图用系统 PhotosPicker，不需要读取权限）
enum LaunchPermissions {
    @MainActor
    static func requestAll() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        if UIImagePickerController.isSourceTypeAvailable(.camera),
           AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
    }
}
