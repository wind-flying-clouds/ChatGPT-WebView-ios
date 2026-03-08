import UIKit
import WebKit

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    
    // MARK: - 新增：底部导航栏组件（全局属性，方便点击事件调用）
    private let bottomStackView = UIStackView()
    private let backBtn = UIButton(type: .system)
    private let refreshBtn = UIButton(type: .system)
    private let forwardBtn = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        print("✅ ViewController loaded (Document Start Sidebar Fix + Voice Mode OK)")

        // MARK: - WebView Configuration
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = .mobile
        config.defaultWebpagePreferences = prefs

        let userContentController = WKUserContentController()

        // Inject BEFORE React hydration: force sidebar closed
        let preHydrationSidebarFix = WKUserScript(
            source: """
            try {
              localStorage.setItem('sidebar-expanded-state', 'false');
              console.log('💥 Injected: sidebar-expanded-state set to false BEFORE hydration');
            } catch (e) {
              console.log('⚠️ Failed to set sidebar state early:', e);
            }
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(preHydrationSidebarFix)

        // Inject viewport tag AFTER DOM builds
        let viewportScript = WKUserScript(source: """
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1.0';
            document.head.appendChild(meta);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        userContentController.addUserScript(viewportScript)

        config.userContentController = userContentController

        // MARK: - Initialize WebView
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        // 移除原autoresizingMask，改用约束（避免和底部栏冲突）
        webView.translatesAutoresizingMaskIntoConstraints = false 
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        view.addSubview(webView)

        // MARK: - Spinner Setup
        activityIndicator.center = view.center
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        activityIndicator.startAnimating()

        // MARK: - 新增：底部导航栏布局（核心！实现均匀分布）
        setupBottomNavigationBar()

        // MARK: - 新增：WebView约束（避免被底部栏遮挡）
        setupWebViewConstraints()

        // MARK: - Load ChatGPT (Stable landing page)
        if let url = URL(string: "https://chat.openai.com") {
            let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.webView.load(request)
            }
        }
    }

    // MARK: - 新增：配置底部导航栏（均匀分布核心逻辑）
    private func setupBottomNavigationBar() {
        // 1. 配置底部按钮（图标+文字，可替换成自定义图标）
        configureBottomButton(backBtn, title: "返回", imageName: "chevron.left", action: #selector(backBtnTapped))
        configureBottomButton(refreshBtn, title: "刷新", imageName: "arrow.clockwise", action: #selector(refreshBtnTapped))
        configureBottomButton(forwardBtn, title: "前进", imageName: "chevron.right", action: #selector(forwardBtnTapped))
        
        // 2. 配置StackView（实现均匀分布的核心）
        bottomStackView.axis = .horizontal          // 水平排列
        bottomStackView.alignment = .center         // 按钮垂直居中
        bottomStackView.distribution = .equalSpacing// 按钮间距均匀（关键！）
        bottomStackView.spacing = 10                // 按钮间基础间距
        bottomStackView.translatesAutoresizingMaskIntoConstraints = false
        bottomStackView.backgroundColor = .systemGray6 // 底部栏背景色（可选）
        
        // 3. 添加按钮到StackView
        bottomStackView.addArrangedSubview(backBtn)
        bottomStackView.addArrangedSubview(refreshBtn)
        bottomStackView.addArrangedSubview(forwardBtn)
        
        // 4. 添加StackView到视图
        view.addSubview(bottomStackView)
        
        // 5. StackView约束（固定在底部）
        NSLayoutConstraint.activate([
            bottomStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),  // 左内边距
            bottomStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), // 右内边距
            bottomStackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), // 贴底部安全区
            bottomStackView.heightAnchor.constraint(equalToConstant: 60) // 底部栏高度
        ])
    }

    // MARK: - 新增：统一配置底部按钮样式
    private func configureBottomButton(_ btn: UIButton, title: String, imageName: String, action: Selector) {
        btn.setTitle(title, for: .normal)
        btn.setImage(UIImage(systemName: imageName), for: .normal) // 使用系统图标（也可替换成自定义图片）
        btn.titleEdgeInsets = UIEdgeInsets(top: 5, left: 0, bottom: 0, right: 0) // 图文间距
        btn.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 5, right: 0)
        btn.tintColor = .systemBlue // 按钮颜色
        btn.addTarget(self, action: action, for: .touchUpInside) // 绑定点击事件
    }

    // MARK: - 新增：WebView约束（适配底部栏）
    private func setupWebViewConstraints() {
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomStackView.topAnchor) // WebView底部贴底部栏顶部
        ])
    }

    // MARK: - 新增：底部按钮点击事件
    @objc private func backBtnTapped() {
        if webView.canGoBack {
            webView.goBack()
            print("🔙 WebView go back")
        }
    }

    @objc private func refreshBtnTapped() {
        webView.reload()
        print("🔄 WebView refreshed")
    }

    @objc private func forwardBtnTapped() {
        if webView.canGoForward {
            webView.goForward()
            print("➡️ WebView go forward")
        }
    }

    // MARK: - WebView Delegates
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
        print("✅ Page finished loading")

        // Optional: bind hold-to-speak icon to mic (future-facing)
        let voiceBind = """
        setTimeout(() => {
          try {
            const voiceBtn = document.querySelector('[aria-label="Hold to speak"]');
            const micBtn = document.querySelector('[aria-label="Start voice input"]');
            if (voiceBtn && micBtn) {
              voiceBtn.addEventListener('mousedown', () => micBtn.click());
              console.log('🎤 Hold-to-speak rebound to mic');
            }
          } catch (e) {
            console.log('❌ Mic bind failed:', e);
          }
        }, 3000);
        """
        webView.evaluateJavaScript(voiceBind, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
        print("❌ Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: "Alert", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        self.present(alert, animated: true, completion: nil)
    }
}