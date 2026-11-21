import Foundation

// 扩展入口（Package.swift 用 `-e _MolaShareMain` 指定，覆盖 xtool 默认的 `_NSExtensionMain`）。
// 原因：ld64.lld 剔除死代码时会丢掉没被引用的 ObjC 类登记（__objc_classlist），
// 扩展二进制里就找不到 Info.plist 指定的 NSExtensionPrincipalClass。这里先引用一次类，让它保留并完成注册，再交给系统入口。

@_silgen_name("NSExtensionMain")
private func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_cdecl("MolaShareMain")
public func molaShareMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    _ = NSStringFromClass(ShareViewController.self)
    return NSExtensionMain(argc, argv)
}
