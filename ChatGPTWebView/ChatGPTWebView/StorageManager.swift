import UIKit
import WebKit

final class StorageManager {

    static let shared = StorageManager()

    /// 自动清理阈值：150MB
    private let autoClearThresholdBytes: Int64 = 150 * 1024 * 1024

    /// [Fix-1] 增加 ServiceWorkerRegistrations + MemoryCache，覆盖更多缓存类型
    /// WKWebsiteDataTypeFetchCache 不是公开常量，已移除
    private let cacheOnlyDataTypes: Set<String> = {
        var types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeMemoryCache
        ]
        if #available(iOS 14.0, *) {
            types.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
        }
        return types
    }()

    /// [Fix-3] 防止并发重复清理
    private var isTrimming = false

    /// [Fix-3] 上次检查时间戳，限制最小检查间隔
    private var lastCheckDate: Date?

    /// 最短检查间隔：30 分钟
    private let minimumCheckInterval: TimeInterval = 30 * 60

    private init() {}

    // MARK: - 前台检查入口（由 SceneDelegate 调用）

    func checkAndTrimIfNeeded() {
        guard !isTrimming else { return }

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
            // [Fix-2] WKWebsiteDataRecord 没有公开 size 属性（Mirror 反射也脆弱）。
            // 改用按数据类型加权估算：
            //   含 DiskCache 的记录体积大 → 保守估 ~5MB/条
            //   其余（SW、LocalStorage 等） → 估 ~0.5MB/条
            let total = records.reduce(Int64(0)) { sum, record in
                let hasDisk = record.dataTypes.contains(WKWebsiteDataTypeDiskCache)
                let weight: Int64 = hasDisk ? 5 * 1024 * 1024 : 512 * 1024
                return sum + weight
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
