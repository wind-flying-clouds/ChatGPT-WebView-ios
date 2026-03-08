import UIKit

// 自定义 TabBar，在 layoutSubviews 中强制均匀分布
// 使用 `is UIControl` 判断按钮，避免 iOS 16 中类名带模块前缀导致字符串匹配失败
final class FilledTabBar: UITabBar {
    override func layoutSubviews() {
        super.layoutSubviews()

        guard let items = self.items, !items.isEmpty else { return }
        let totalWidth = bounds.width
        guard totalWidth > 0 else { return }

        // UITabBarButton 继承自 UIControl，用类型判断比字符串匹配更可靠
        let buttons = subviews
            .filter { $0 is UIControl }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }

        guard buttons.count == items.count else { return }

        let itemWidth = floor(totalWidth / CGFloat(buttons.count))
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * itemWidth,
                y: button.frame.origin.y,
                width: itemWidth,
                height: button.frame.height
            )
        }
    }
}

final class MainTabBarController: UITabBarController {

    override func loadView() {
        super.loadView()
        setValue(FilledTabBar(), forKey: "tabBar")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.itemPositioning = .fill
        let webControllers = Service.allCases.map { service in
            let webController = WebContainerViewController(service: service)
            return UINavigationController(rootViewController: webController)
        }
        let notesController = UINavigationController(rootViewController: NotesViewController())
        viewControllers = webControllers + [notesController]
    }
}
