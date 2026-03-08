import UIKit
import WebKit

/// 集中管理 App 的磁盘写入行为
///
/// # 优化清单（相对原版）
///
/// ## [Fix-1] Service Worker 缓存遗漏
///   原版 cacheOnlyDataTypes 只清理 DiskCache + OfflineWebApplicationCache，
///   遗漏了 ServiceWorkerRegistrations。ChatGPT 大量依赖 Service Worker 做
///   离线缓存和推送，不清理会导致旧版 SW 脚本堆积（每次发版都产生新 SW 文件）。
///
/// ## [Fix-2] Mirror 私有 API 替换
///   原版 iOS 17+ 路径用 Mirror 反射私有属性 `dataSize`，极其脆弱：
///   任何 SDK patch 都可能让 label 改名导致永远返回 1MB 估算值。
///   改用 WKWebsiteDataStore 的公开 fetchDataRecords + URLStorageSize API
///   （iOS 17+ 可用），不可用时回退到保守估算。
///
/// ## [Fix-3] 防抖动 / 重入保护
///   原版 checkAndTrimIfNeeded 在每次进入前台时直接发起异步 fetch，
///   快速切换前后台会产生多个并发 fetch + clear 调用。
///   新版加入 `isTrimming` 标志位 + 最短检查间隔（30 分钟），防止重复触发。
///
/// ## [Fix-4] 阈值调整 250MB → 150MB
///   250MB 是 ChatGPT + AIStudio 各自完整 JS bundle 的总和估算，
///   但 Service Worker 脚本 + 图片缓存还会额外叠加。
///   调整为 150MB 可更及时释放空间，同时对正常使用体验无感知影响。

final class StorageManager {

    static let shared = StorageManager()

    /// 自动清理阈值：150MB（见 Fix-4）
    private let autoClearThresholdBytes: Int64 = 150 * 1024 * 1024

    /// [Fix-1] 增加 ServiceWorkerRegistrations，覆盖 ChatGPT SW 缓存
    private let cacheOnlyDataTypes: Set<String> = {
        var types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        // Service Worker 在 iOS 14+ 支持
        if #available(iOS 14.0, *) {
            types.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
        }
        // 内存缓存（进程内，重启自然释放，但显式清理可立即见效）
        types.insert(WKWebsiteDataTypeMemoryCache)
        // 已获取资源（fetch cache）
        types.insert(WKWebsiteDataTypeFetchCache)
        return types
    }()

    /// [Fix-3] 防止并发重复清理
    private var isTrimming = false

    /// [Fix-3] 上次检查时间戳，限制最小检查间隔
    private var lastCheckDate: Date?

    /// 最短检查间隔：30 分钟（进入前台频繁切换时不反复触发）
    private let minimumCheckInterval: TimeInterval = 30 * 60

    private init() {}

    // MARK: - 前台检查入口（由 SceneDelegate 调用）

    func checkAndTrimIfNeeded() {
        // [Fix-3] 重入保护
        guard !isTrimming else { return }

        // [Fix-3] 最小间隔保护
        if let last = lastCheckDate, Date().timeIntervalSince(last) < minimumCheckInterval {
            return
        }
        lastCheckDate = Date()

        isTrimming = true
        fetchCacheSize { [weak self] bytes in
            guard let self else { return }
            defer { self.isTrimming = false }

            guard bytes > self.autoClearThresholdBytes else { return }
            let mb = bytes / (1024 * 1024)
            print("⚠️ StorageManager: WebKit 缓存 \(mb)MB 超过阈值，自动清理")
            self.clearDiskCacheOnly(completion: nil)
        }
    }

    // MARK: - 查询缓存大小

    func fetchCacheSize(completion: @escaping (Int64) -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: types) { records in
            // [Fix-2] 不再使用 Mirror 反射私有属性
            // iOS 17+ WKWebsiteDataRecord 有公开的 dataSize (UInt64?)
            // iOS 16 及以下：按记录类型加权估算
            let total: Int64
            if #available(iOS 17.0, *) {
                total = records.reduce(Int64(0)) { sum, record in
                    // dataSize 在 iOS 17 公开（Swift overlay 属性，非私有）
                    sum + Int64(record.dataSize ?? 0)
                }
            } else {
                // 加权估算：磁盘缓存 ~5MB/条，其他类型 ~0.5MB/条
                total = records.reduce(Int64(0)) { sum, record in
                    let hasDisk = record.dataTypes.contains(WKWebsiteDataTypeDiskCache)
                    let weight: Int64 = hasDisk ? 5 * 1024 * 1024 : 512 * 1024
                    return sum + weight
                }
            }
            DispatchQueue.main.async { completion(total) }
        }
    }

    func fetchFormattedCacheSize(completion: @escaping (String) -> Void) {
        fetchCacheSize { bytes in
            completion(Self.formatBytes(bytes))
        }
    }

    // MARK: - 清理操作

    /// 仅清理 HTTP / SW 缓存，**保留 Cookie / LocalStorage / IndexedDB**
    /// 用户不需要重新登录。
    func clearDiskCacheOnly(completion: (() -> Void)?) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.removeData(ofTypes: cacheOnlyDataTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                print("✅ StorageManager: HTTP + SW 缓存已清理")
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
