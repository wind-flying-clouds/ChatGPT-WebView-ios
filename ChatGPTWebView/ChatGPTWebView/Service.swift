import Foundation
import WebKit

struct InjectedJavaScript {
    let documentStart: String?
    let documentEnd: String?
    let didFinish: String?
}

enum Service: CaseIterable {
    case chatgpt
    case aistudio

    var homeURL: URL {
        switch self {
        case .chatgpt:
            return URL(string: "https://chatgpt.com/")!
        case .aistudio:
            return URL(string: "https://aistudio.google.com/prompts/new_chat")!
        }
    }

    var title: String {
        switch self {
        case .chatgpt:  return "ChatGPT"
        case .aistudio: return "AIStudio"
        }
    }

    var tabIconSystemName: String {
        switch self {
        case .chatgpt:  return "globe"
        case .aistudio: return "sparkles"
        }
    }

    var preferredContentMode: WKWebpagePreferences.ContentMode {
        switch self {
        case .aistudio: return .desktop   // AI Studio 仅有桌面版
        case .chatgpt:  return .mobile
        }
    }

    var userAgentOverride: String? {
        switch self {
        case .chatgpt:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        case .aistudio:
            return nil
        }
    }

    var injectedJavaScript: InjectedJavaScript? {
        switch self {
        case .chatgpt:
            return InjectedJavaScript(
                documentStart: """
                try {
                  localStorage.setItem('sidebar-expanded-state', 'false');
                } catch (_) {}
                """,
                // [Fix-5] 移除 debug console.log，生产代码不应写控制台日志
                // [Fix-6] documentEnd 注入 viewport meta
                documentEnd: """
                (function() {
                  var existing = document.querySelector('meta[name="viewport"]');
                  if (!existing) {
                    var meta = document.createElement('meta');
                    meta.name = 'viewport';
                    meta.content = 'width=device-width, initial-scale=1.0';
                    document.head.appendChild(meta);
                  }
                })();
                """,
                // [Fix-7] 防止多次导航时 setTimeout 回调叠加
                // 原版每次 didFinish 都注册一个 3s 定时器，快速翻页时会有 N 个并发回调
                // 改用 window.__micBindDone 标志位，确保只绑定一次
                didFinish: """
                (function() {
                  if (window.__micBindDone) return;
                  window.__micBindDone = true;
                  setTimeout(function() {
                    try {
                      var voiceBtn = document.querySelector('[aria-label="Hold to speak"]');
                      var micBtn   = document.querySelector('[aria-label="Start voice input"]');
                      if (voiceBtn && micBtn) {
                        voiceBtn.addEventListener('mousedown', function() { micBtn.click(); });
                      }
                    } catch (_) {}
                  }, 3000);
                })();
                """
            )
        case .aistudio:
            return InjectedJavaScript(
                documentStart: nil,
                documentEnd: """
                (function() {
                  var existing = document.querySelector('meta[name="viewport"]');
                  if (existing) existing.remove();
                  var meta = document.createElement('meta');
                  meta.name = 'viewport';
                  meta.content = 'width=1280, initial-scale=0.33, minimum-scale=0.1, maximum-scale=5.0, user-scalable=yes';
                  document.head.appendChild(meta);
                })();
                """,
                didFinish: nil
            )
        }
    }

    var zoomDefaultsKey: String {
        switch self {
        case .chatgpt:  return "zoomScale.chatgpt"
        case .aistudio: return "zoomScale.aistudio"
        }
    }

    /// [Fix-8] 新增：lastKnownURL 持久化 key（重启后恢复上次页面）
    var lastURLDefaultsKey: String {
        switch self {
        case .chatgpt:  return "lastURL.chatgpt"
        case .aistudio: return "lastURL.aistudio"
        }
    }

    var websiteDataDomain: String {
        switch self {
        case .chatgpt:  return "chatgpt.com"
        case .aistudio: return "aistudio.google.com"
        }
    }
}
