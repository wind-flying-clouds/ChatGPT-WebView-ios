import UIKit
import WebKit

final class WebContainerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let sharedProcessPool = WKProcessPool()

    private(set) var webView: WKWebView?
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let service: Service
    private var lastKnownURL: URL?
    private var memoryWarningObserver: NSObjectProtocol?

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

    var serviceType: Service {
        service
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureActivityIndicator()
        configureNavigationItems()
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

    // Auto Layout 固定 activityIndicator，修复横屏后指示器偏移
    private func configureActivityIndicator() {
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
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
        view.insertSubview(newWebView, belowSubview: activityIndicator)
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
                let script = WKUserScript(source: documentStart, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                userContentController.addUserScript(script)
            }
            if let documentEnd = injectedJavaScript.documentEnd {
                let script = WKUserScript(source: documentEnd, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                userContentController.addUserScript(script)
            }
        }
        config.userContentController = userContentController
        return config
    }

    private func loadLastURLIfNeeded() {
        guard let webView else { return }
        guard webView.url == nil else { return }
        activityIndicator.startAnimating()
        let destination = lastKnownURL ?? service.homeURL
        // 有缓存直接用，减少网络等待；Clear Site Data 后会用 .reloadIgnoringLocalCacheData
        let request = URLRequest(url: destination, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        webView.load(request)
    }

    @objc private func openInSafari() {
        let destination = webView?.url ?? service.homeURL
        UIApplication.shared.open(destination, options: [:], completionHandler: nil)
    }

    // MARK: - Action Menu（含存储信息）

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

        // 存储管理分区
        alert.addAction(UIAlertAction(title: "Clear Site Data", style: .destructive) { [weak self] _ in
            self?.clearSiteData()
        })

        // 新增：仅清理 HTTP 缓存，不影响登录状态
        alert.addAction(UIAlertAction(title: "Clear HTTP Cache Only", style: .default) { [weak self] _ in
            self?.clearHttpCacheOnly()
        })

        // 新增：查看当前缓存用量
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

    /// 仅清理 HTTP 磁盘缓存，保留 Cookie / LocalStorage，用户无需重新登录
    private func clearHttpCacheOnly() {
        activityIndicator.startAnimating()
        StorageManager.shared.clearDiskCacheOnly { [weak self] in
            self?.activityIndicator.stopAnimating()
            // 强制重新加载以验证缓存已清空
            if let webView = self?.webView {
                let request = URLRequest(
                    url: webView.url ?? self!.service.homeURL,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 30
                )
                webView.load(request)
            }
        }
    }

    /// 展示当前 WebKit 缓存用量，并提供清理入口
    private func showStorageUsage() {
        // 先显示一个"正在查询"的 alert，避免空白等待
        let loadingAlert = UIAlertController(
            title: "Storage Usage",
            message: "Calculating…",
            preferredStyle: .alert
        )
        present(loadingAlert, animated: true)

        StorageManager.shared.fetchFormattedCacheSize { [weak self] formatted in
            guard let self else { return }
            loadingAlert.dismiss(animated: false) {
                let info = UIAlertController(
                    title: "Storage Usage",
                    message: "WebKit cache: \(formatted)\n\nThis includes cached pages, scripts, and images for all tabs. Clearing the HTTP cache frees space without logging you out.",
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
        present(alert, animated: true, completion: nil)
    }

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
        // zoom == 1.0 时跳过 JS 注入，节省每次页面加载的脚本执行开销
        guard scale != 1.0 else { return }
        applyZoom(scale: scale)
        updateZoomButtonTitle(scale: scale)
    }

    private func updateZoomButtonTitle(scale: Double) {
        let percent = Int(round(scale * 100))
        zoomBarButtonItem.title = "Zoom \(percent)%"
    }

    // 使用标准 CSS transform 替代非标准 zoom 属性
    private func applyZoom(scale: Double) {
        guard let webView else { return }
        let formattedScale = String(format: "%.2f", scale)
        let script = """
        (function() {
          var scale = \(formattedScale);
          var el = document.body || document.documentElement;
          if (el) {
            el.style.transform = 'scale(' + scale + ')';
            el.style.transformOrigin = 'top left';
            el.style.width = (100 / scale) + '%';
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
        // Clear Site Data 后强制从服务器重新加载，不使用本地缓存
        let request = URLRequest(url: service.homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(request)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
        lastKnownURL = webView.url ?? lastKnownURL
        if let didFinishScript = service.injectedJavaScript?.didFinish {
            webView.evaluateJavaScript(didFinishScript, completionHandler: nil)
        }
        applyStoredZoomIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        print("❌ Navigation failed: \(error.localizedDescription)")
    }

    // DNS 错误、超时等在 provisional 阶段触发，原代码 spinner 永不停止
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        print("❌ Provisional navigation failed: \(error.localizedDescription)")
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
        present(alert, animated: true, completion: nil)
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

        // 非当前 Tab：卸载整个 WebView 释放内存
        if !isSelectedTab {
            unloadIfNeeded()
            return
        }

        // 当前 Tab 也受内存压力时：清空前进/后退历史，释放页面快照占用的内存
        // WKWebView 的前进后退列表会在内存中保留每个页面的快照（几MB到几十MB）
        // 通过重新加载当前页来隐式清空历史列表
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
