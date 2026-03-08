import UIKit
import WebKit

final class WebContainerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let sharedProcessPool = WKProcessPool()

    private(set) var webView: WKWebView?
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let service: Service
    private var memoryWarningObserver: NSObjectProtocol?

    // [Fix-8] lastKnownURL 改为持久化到 UserDefaults，重启后恢复上次页面
    private var lastKnownURL: URL? {
        get {
            guard let str = UserDefaults.standard.string(forKey: service.lastURLDefaultsKey),
                  let url = URL(string: str) else { return nil }
            return url
        }
        set {
            if let url = newValue {
                UserDefaults.standard.set(url.absoluteString, forKey: service.lastURLDefaultsKey)
            }
        }
    }

    // 内存缓存 zoom，避免高频读 UserDefaults
    private var _cachedZoomScale: Double?
    private var cachedZoomScale: Double {
        get {
            if let cached = _cachedZoomScale { return cached }
            let value = (UserDefaults.standard.object(forKey: service.zoomDefaultsKey) as? Double)
                .map { clampZoomScale($0) } ?? 1.0
            _cachedZoomScale = value
            return value
        }
        set {
            let clamped = clampZoomScale(newValue)
            _cachedZoomScale = clamped
            UserDefaults.standard.set(clamped, forKey: service.zoomDefaultsKey)
        }
    }

    // [Fix-9] 网络错误视图：加载失败时展示重试入口，而非空白页 + 仅打印日志
    private lazy var errorView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "无法连接\n请检查网络后重试"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)

        let retryButton = UIButton(type: .system)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retryButton.layer.cornerRadius = 10
        retryButton.backgroundColor = .systemBlue.withAlphaComponent(0.15)
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 28, bottom: 10, right: 28)
        retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 48),
            icon.widthAnchor.constraint(equalToConstant: 48),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40)
        ])
        return container
    }()

    private lazy var menuBarButtonItem = UIBarButtonItem(
        title: "⋯",
        style: .plain,
        target: self,
        action: #selector(showActionMenu)
    )
    private lazy var zoomBarButtonItem = UIBarButtonItem(
        title: "Zoom 100%",
        style: .plain,
        target: self,
        action: #selector(showZoomOptions)
    )
    private let zoomStep: Double = 0.05
    private let minZoomScale: Double = 0.5
    private let maxZoomScale: Double = 2.0

    init(service: Service) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = service.title
        tabBarItem = UITabBarItem(title: service.title, image: UIImage(systemName: service.tabIconSystemName), tag: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var serviceType: Service { service }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureActivityIndicator()
        configureNavigationItems()
        configureErrorView()
        recreateWebViewIfNeeded()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSelection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        handleDeselection()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func unloadIfNeeded() {
        guard let webView else { return }
        lastKnownURL = webView.url ?? lastKnownURL
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        activityIndicator.stopAnimating()
    }

    // MARK: - Layout

    private func configureActivityIndicator() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureErrorView() {
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureNavigationItems() {
        let safariButton = UIBarButtonItem(
            image: UIImage(systemName: "safari"),
            style: .plain,
            target: self,
            action: #selector(openInSafari)
        )
        navigationItem.rightBarButtonItems = [menuBarButtonItem, safariButton, zoomBarButtonItem]
        updateZoomButtonTitle(scale: cachedZoomScale)
    }

    private func recreateWebViewIfNeeded() {
        guard webView == nil else {
            webView?.isHidden = false
            return
        }
        let config = makeConfiguration()
        let newWebView = WKWebView(frame: .zero, configuration: config)
        if let userAgent = service.userAgentOverride {
            newWebView.customUserAgent = userAgent
        }
        newWebView.translatesAutoresizingMaskIntoConstraints = false
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.backgroundColor = .systemBackground
        newWebView.isOpaque = false
        newWebView.scrollView.contentInsetAdjustmentBehavior = .automatic
        if service.preferredContentMode == .desktop {
            newWebView.scrollView.minimumZoomScale = 0.1
            newWebView.scrollView.maximumZoomScale = 5.0
            newWebView.scrollView.bouncesZoom = true
        }
        // 插入到 activityIndicator 和 errorView 下方
        view.insertSubview(newWebView, at: 0)
        NSLayoutConstraint.activate([
            newWebView.topAnchor.constraint(equalTo: view.topAnchor),
            newWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            newWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            newWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView = newWebView
        loadLastURLIfNeeded()
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = service.preferredContentMode
        config.defaultWebpagePreferences = prefs

        let userContentController = WKUserContentController()
        if let injectedJavaScript = service.injectedJavaScript {
            if let documentStart = injectedJavaScript.documentStart {
                userContentController.addUserScript(
                    WKUserScript(source: documentStart, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
            }
            if let documentEnd = injectedJavaScript.documentEnd {
                userContentController.addUserScript(
                    WKUserScript(source: documentEnd, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                )
            }
        }
        config.userContentController = userContentController
        return config
    }

    private func loadLastURLIfNeeded() {
        guard let webView, webView.url == nil else { return }
        activityIndicator.startAnimating()
        errorView.isHidden = true
        let destination = lastKnownURL ?? service.homeURL
        let request = URLRequest(url: destination, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        webView.load(request)
    }

    @objc private func openInSafari() {
        let destination = webView?.url ?? service.homeURL
        UIApplication.shared.open(destination, options: [:], completionHandler: nil)
    }

    // MARK: - Error Handling

    @objc private func retryLoad() {
        errorView.isHidden = true
        activityIndicator.startAnimating()
        if let webView, let url = webView.url ?? lastKnownURL {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView.load(request)
        } else {
            loadLastURLIfNeeded()
        }
    }

    private func showError() {
        activityIndicator.stopAnimating()
        errorView.isHidden = false
    }

    // MARK: - Action Menu

    @objc private func showActionMenu() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        let backAction = UIAlertAction(title: "Back", style: .default) { [weak self] _ in
            self?.webView?.goBack()
        }
        backAction.isEnabled = webView?.canGoBack ?? false
        alert.addAction(backAction)

        let forwardAction = UIAlertAction(title: "Forward", style: .default) { [weak self] _ in
            self?.webView?.goForward()
        }
        forwardAction.isEnabled = webView?.canGoForward ?? false
        alert.addAction(forwardAction)

        alert.addAction(UIAlertAction(title: "Reload", style: .default) { [weak self] _ in
            self?.webView?.reload()
        })
        alert.addAction(UIAlertAction(title: "Open in Safari", style: .default) { [weak self] _ in
            self?.openInSafari()
        })
        alert.addAction(UIAlertAction(title: "Clear Site Data", style: .destructive) { [weak self] _ in
            self?.clearSiteData()
        })
        alert.addAction(UIAlertAction(title: "Clear HTTP Cache Only", style: .default) { [weak self] _ in
            self?.clearHttpCacheOnly()
        })
        alert.addAction(UIAlertAction(title: "Storage Usage…", style: .default) { [weak self] _ in
            self?.showStorageUsage()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = menuBarButtonItem
        }
        present(alert, animated: true)
    }

    // MARK: - Storage Actions

    private func clearHttpCacheOnly() {
        activityIndicator.startAnimating()
        StorageManager.shared.clearDiskCacheOnly { [weak self] in
            guard let self else { return }
            self.activityIndicator.stopAnimating()
            // [Fix-10] 原版有 self! 强制解包，改为安全解包
            let url = self.webView?.url ?? self.service.homeURL
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            self.webView?.load(request)
        }
    }

    private func showStorageUsage() {
        // [Fix-11] 去除 loading alert → dismiss → present 的双重动画闪烁
        // 改为：直接计算，完成后一次性展示结果 alert
        var progressAlert: UIAlertController? = UIAlertController(
            title: "Storage Usage",
            message: "Calculating…",
            preferredStyle: .alert
        )
        present(progressAlert!, animated: true)

        StorageManager.shared.fetchFormattedCacheSize { [weak self] formatted in
            guard let self else { return }
            progressAlert?.dismiss(animated: true) {
                progressAlert = nil
                let info = UIAlertController(
                    title: "Storage Usage",
                    message: "WebKit 缓存：\(formatted)\n\n包含所有标签页的脚本、图片和 Service Worker 缓存。\n清理 HTTP 缓存不会登出。",
                    preferredStyle: .alert
                )
                info.addAction(UIAlertAction(title: "Clear HTTP Cache", style: .destructive) { [weak self] _ in
                    self?.clearHttpCacheOnly()
                })
                info.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(info, animated: true)
            }
        }
    }

    @objc private func showZoomOptions() {
        let alert = UIAlertController(title: "Zoom", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Zoom Out (−5%)", style: .default) { [weak self] _ in
            guard let self else { return }
            self.adjustZoom(by: -self.zoomStep)
        })
        alert.addAction(UIAlertAction(title: "Zoom In (+5%)", style: .default) { [weak self] _ in
            guard let self else { return }
            self.adjustZoom(by: self.zoomStep)
        })
        alert.addAction(UIAlertAction(title: "Reset (100%)", style: .default) { [weak self] _ in
            self?.setZoom(scale: 1.0)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = zoomBarButtonItem
        }
        present(alert, animated: true)
    }

    // MARK: - Zoom

    private func clampZoomScale(_ scale: Double) -> Double {
        min(max(scale, minZoomScale), maxZoomScale)
    }

    private func adjustZoom(by delta: Double) {
        setZoom(scale: cachedZoomScale + delta)
    }

    private func setZoom(scale: Double) {
        let clamped = clampZoomScale(scale)
        cachedZoomScale = clamped
        applyZoom(scale: clamped)
        updateZoomButtonTitle(scale: clamped)
    }

    private func applyStoredZoomIfNeeded() {
        let scale = cachedZoomScale
        guard scale != 1.0 else { return }
        applyZoom(scale: scale)
        updateZoomButtonTitle(scale: scale)
    }

    private func updateZoomButtonTitle(scale: Double) {
        let percent = Int(round(scale * 100))
        zoomBarButtonItem.title = "Zoom \(percent)%"
    }

    private func applyZoom(scale: Double) {
        guard let webView else { return }
        let formattedScale = String(format: "%.2f", scale)
        let script = """
        (function() {
          var s = \(formattedScale);
          var el = document.body || document.documentElement;
          if (el) {
            el.style.transform = 'scale(' + s + ')';
            el.style.transformOrigin = 'top left';
            el.style.width = (100 / s) + '%';
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func clearSiteData() {
        StorageManager.shared.clearAllData(for: service.websiteDataDomain) { [weak self] in
            self?.loadServiceHomeURL()
        }
    }

    private func loadServiceHomeURL() {
        guard let webView else { return }
        let request = URLRequest(url: service.homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(request)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
        errorView.isHidden = true
        lastKnownURL = webView.url ?? lastKnownURL
        if let didFinishScript = service.injectedJavaScript?.didFinish {
            webView.evaluateJavaScript(didFinishScript, completionHandler: nil)
        }
        applyStoredZoomIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        showError()
    }

    // [Fix-9] DNS 错误、超时等展示错误视图 + 重试按钮
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        showError()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: "Alert", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    // MARK: - Tab Lifecycle

    private func handleSelection() {
        recreateWebViewIfNeeded()
        webView?.isHidden = false
        loadLastURLIfNeeded()
    }

    private func handleDeselection() {
        lastKnownURL = webView?.url ?? lastKnownURL
        webView?.stopLoading()
        webView?.isHidden = true
        activityIndicator.stopAnimating()
    }

    private func handleMemoryWarning() {
        guard view.window != nil else { return }

        if !isSelectedTab {
            unloadIfNeeded()
            return
        }

        // 当前 Tab 受内存压力时：重载清空前进/后退历史快照
        if let webView, let currentURL = webView.url {
            let request = URLRequest(url: currentURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            webView.load(request)
        }
    }

    private var isSelectedTab: Bool {
        guard let tabBarController else { return true }
        if let navigationController {
            return tabBarController.selectedViewController === navigationController
        }
        return tabBarController.selectedViewController === self
    }
}
