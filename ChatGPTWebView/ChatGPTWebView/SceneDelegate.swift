import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainTabBarController()
        window.makeKeyAndVisible()
        self.window = window
    }

    /// App 每次从后台切回前台时触发缓存检查。
    /// 选择在此时机（而非启动时）是因为：
    /// - 启动时检查会与页面加载竞争 I/O，影响首屏速度
    /// - 进入前台时用户尚未开始操作，是执行后台清理的最佳窗口
    func sceneWillEnterForeground(_ scene: UIScene) {
        StorageManager.shared.checkAndTrimIfNeeded()
    }
}
