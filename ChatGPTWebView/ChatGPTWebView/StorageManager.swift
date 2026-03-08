import UIKit
import WebKit

/// 集中管理 App 的磁盘写入行为，解决以下问题：
///
/// 1. **WebKit 磁盘缓存无上限**
///    WKWebView 使用独立的 WebKit 进程缓存，完全绕过 URLCache。
///    ChatGPT + AIStudio 都是重型 SPA，JS bundle + 图片 + Service Worker
///    累积可轻松超过 300MB，且系统不会主动清理（只有低存储压力时才会）。
///
/// 2. **旧版本 JS bundle 堆积**
///    ChatGPT / AIStudio 频繁发版，每次发版都产生新的 hash 文件名，
///    旧版本缓存不会被新版本覆盖，导致缓存持续膨胀。
///
/// 3. **UserDefaults 大文件写入**（已在 NotesViewController 修复）
///    UserDefaults 每次写入会序列化整个 plist，大文本拖慢启动速度。
///
/// 解决策略：
/// - App 每次进入前台时检查 WebKit 缓存大小
/// - 超过阈值（默认 250MB）时，自动清理 HTTP 磁盘缓存
///   （保留 Cookies / LocalStorage / IndexedDB，不影响登录状态）
/// - 提供查询当前缓存用量的 API，供 UI 展示

final class StorageManager {

    static let shared = StorageManager()

    /// 自动清理触发阈值（字节）。超过此值时，下次进入前台自动清理 HTTP 磁盘缓存。
    /// 250MB：足够存下两个站点的完整 JS bundle，同时防止无限膨胀。
    private let autoClearThresholdBytes: Int64 = 250 * 1024 * 1024

    /// 只清理 HTTP 磁盘缓存，保留 Cookie 和 localStorage（登录态依赖这些）
    private let cacheOnlyDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeOfflineWebApplicationCache
    ]

    private init() {}

    // MARK: - 前台检查入口（由 SceneDelegate 调用）

    func checkAndTrimIfNeeded() {
        fetchCacheSize { [weak self] bytes in
            guard let self else { return }
            guard bytes > self.autoClearThresholdBytes else { return }
            let mb = bytes / (1024 * 1024)
            print("⚠️ StorageManager: WebKit 缓存 \(mb)MB 超过阈值，自动清理 HTTP 磁盘缓存")
            self.clearDiskCacheOnly(completion: nil)
        }
    }

    // MARK: - 查询缓存大小

    /// 异步返回 WebKit 所有已知数据记录的估算总字节数。
    /// 注意：WKWebsiteDataRecord 在 iOS 17 以下不暴露精确 size，
    /// 这里通过记录数量 × 经验系数估算；iOS 17+ 可直接读 size 属性。
    func fetchCacheSize(completion: @escaping (Int64) -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            if #available(iOS 17.0, *) {
                // iOS 17+ WKWebsiteDataRecord 有 .size 属性
                let total = records.reduce(Int64(0)) { sum, record in
                    // 用 Mirror 读取私有 size 属性（公开 API 在 iOS 17 beta 后才稳定）
                    sum + Self.recordSize(record)
                }
                DispatchQueue.main.async { completion(total) }
            } else {
                // iOS 16 及以下：保守估算每条记录 ~2MB（适用于 ChatGPT/AIStudio 场景）
                let estimated = Int64(records.count) * 2 * 1024 * 1024
                DispatchQueue.main.async { completion(estimated) }
            }
        }
    }

    /// 格式化为人类可读字符串
    func fetchFormattedCacheSize(completion: @escaping (String) -> Void) {
        fetchCacheSize { bytes in
            let formatted = Self.formatBytes(bytes)
            completion(formatted)
        }
    }

    // MARK: - 清理操作

    /// 仅清理 HTTP 磁盘缓存，**保留 Cookie / LocalStorage / IndexedDB**
    /// 用户不需要重新登录。
    func clearDiskCacheOnly(completion: (() -> Void)?) {
        let dataStore = WKWebsiteDataStore.default()
        let since = Date.distantPast
        dataStore.removeData(ofTypes: cacheOnlyDataTypes, modifiedSince: since) {
            DispatchQueue.main.async {
                print("✅ StorageManager: HTTP 磁盘缓存已清理")
                completion?()
            }
        }
    }

    /// 清理指定域名的全部数据（包括 Cookie），等价于"清除站点数据 + 登出"
    func clearAllData(for domain: String, completion: (() -> Void)?) {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter {
                $0.displayName.lowercased().contains(domain.lowercased())
            }
            dataStore.removeData(ofTypes: types, for: matching) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    // MARK: - Helpers

    @available(iOS 17.0, *)
    private static func recordSize(_ record: WKWebsiteDataRecord) -> Int64 {
        // WKWebsiteDataRecord.dataSize 在 iOS 17 正式暴露
        // 用 Mirror 以兼容旧 SDK 编译
        let mirror = Mirror(reflecting: record)
        for child in mirror.children {
            if child.label == "dataSize", let size = child.value as? Int64 {
                return size
            }
        }
        return 1024 * 1024 // 无法读取时保守估算 1MB
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
