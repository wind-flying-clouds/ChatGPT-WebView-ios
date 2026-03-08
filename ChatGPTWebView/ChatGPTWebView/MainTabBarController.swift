import UIKit

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let webControllers = Service.allCases.map { service in
            let webController = WebContainerViewController(service: service)
            return UINavigationController(rootViewController: webController)
        }
        let notesController = UINavigationController(rootViewController: NotesViewController())
        viewControllers = webControllers + [notesController]
        tabBar.itemPositioning = .fill
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        redistributeTabBarItems()
    }

    private func redistributeTabBarItems() {
        guard let items = tabBar.items, !items.isEmpty else { return }
        let totalWidth = tabBar.bounds.width
        guard totalWidth > 0 else { return }
        let itemWidth = floor(totalWidth / CGFloat(items.count))

        let buttons = tabBar.subviews
            .filter { String(describing: type(of: $0)) == "UITabBarButton" }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }

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
