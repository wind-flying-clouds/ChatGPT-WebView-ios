import UIKit

final class NotesViewController: UIViewController, UITextViewDelegate {
    private let textView = UITextView()
    private var autosaveTimer: Timer?

    // 优化D：Notes 从 UserDefaults 迁移到文件系统
    // UserDefaults 设计用于存储少量键值偏好（通常 < 100KB），
    // 大段笔记写入会导致整个 UserDefaults plist 序列化/反序列化，拖慢启动时间。
    // 使用 Documents/notes.txt 后，读写是独立 I/O，不影响 App 其他偏好数据。
    private static let notesFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("notes.txt")
    }()

    private var textViewBottomConstraint: NSLayoutConstraint!

    init() {
        super.init(nibName: nil, bundle: nil)
        tabBarItem = UITabBarItem(title: "Notes", image: UIImage(systemName: "note.text"), tag: 0)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        tabBarItem = UITabBarItem(title: "Notes", image: UIImage(systemName: "note.text"), tag: 0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notes"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Send To…", style: .plain, target: self, action: #selector(showSendToMenu)),
            UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector(shareNotes)),
            UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyNotes))
        ]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Clear", style: .plain, target: self, action: #selector(confirmClear)
        )

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.text = loadNotes()

        view.addSubview(textView)

        textViewBottomConstraint = textView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor
        )
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textViewBottomConstraint
        ])

        // 优化D：若旧数据在 UserDefaults，一次性迁移到文件，然后删除 UserDefaults 条目
        migrateFromUserDefaultsIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        saveNotes(textView.text)
    }

    // MARK: - Migration

    private func migrateFromUserDefaultsIfNeeded() {
        let legacyKey = "notes.text"
        guard let legacyText = UserDefaults.standard.string(forKey: legacyKey) else { return }
        // 只在文件还不存在时迁移（防止覆盖用户在新版写入的内容）
        guard !FileManager.default.fileExists(atPath: Self.notesFileURL.path) else {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return
        }
        saveNotes(legacyText)
        textView.text = legacyText
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // MARK: - Storage（文件系统）

    private func loadNotes() -> String {
        (try? String(contentsOf: Self.notesFileURL, encoding: .utf8)) ?? ""
    }

    private func saveNotes(_ text: String) {
        // 异步写入，不阻塞主线程
        let url = Self.notesFileURL
        DispatchQueue.global(qos: .utility).async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Keyboard Handling

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
            let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let keyboardTop = keyboardFrame.minY
        let viewBottom = view.frame.maxY
        let overlap = max(0, viewBottom - keyboardTop)
        let safeBottom = view.safeAreaInsets.bottom
        let offset = max(0, overlap - safeBottom)

        let options = UIView.AnimationOptions(rawValue: curveValue << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.textViewBottomConstraint.constant = -offset
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
            let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let options = UIView.AnimationOptions(rawValue: curveValue << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.textViewBottomConstraint.constant = 0
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.saveNotes(self.textView.text)
        }
    }

    // MARK: - Actions

    @objc private func copyNotes() {
        UIPasteboard.general.string = textView.text
    }

    @objc private func shareNotes() {
        let activity = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(activity, animated: true)
    }

    @objc private func showSendToMenu() {
        let alert = UIAlertController(title: "Send To…", message: nil, preferredStyle: .actionSheet)
        Service.allCases.forEach { service in
            alert.addAction(UIAlertAction(title: service.title, style: .default) { [weak self] _ in
                self?.sendNotes(to: service)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }

    private func sendNotes(to service: Service) {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showEmptyNotesAlert()
            return
        }
        UIPasteboard.general.string = textView.text
        if let tbc = tabBarController {
            selectServiceTab(service, in: tbc)
            showToast(message: "Copied — paste to send", in: tbc.view)
        } else {
            showToast(message: "Copied — paste to send", in: view)
        }
    }

    private func showEmptyNotesAlert() {
        let alert = UIAlertController(
            title: "Notes are empty",
            message: "Add something to send first.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func selectServiceTab(_ service: Service, in tabBarController: UITabBarController) {
        guard let viewControllers = tabBarController.viewControllers else { return }
        if let target = viewControllers.first(where: { controller in
            if let nav = controller as? UINavigationController,
               let webController = nav.viewControllers.first as? WebContainerViewController {
                return webController.serviceType == service
            }
            if let webController = controller as? WebContainerViewController {
                return webController.serviceType == service
            }
            return false
        }) {
            tabBarController.selectedViewController = target
        }
    }

    private func showToast(message: String, in containerView: UIView) {
        let toastLabel = PaddingLabel()
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.text = message
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.layer.cornerRadius = 8
        toastLabel.clipsToBounds = true

        containerView.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 24),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -24)
        ])

        toastLabel.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            toastLabel.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: {
                toastLabel.alpha = 0
            }) { _ in
                toastLabel.removeFromSuperview()
            }
        }
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear Notes?",
            message: "This will remove all text.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.textView.text = ""
            self?.saveNotes("")
        })
        present(alert, animated: true)
    }
}

private final class PaddingLabel: UILabel {
    private let textInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}
