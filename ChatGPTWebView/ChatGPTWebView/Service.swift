import Foundation
import WebKit

struct InjectedJavaScript {
    let documentStart: String?
    let documentEnd: String?
    let didFinish: String?
}

enum Service: CaseIterable {
    // 底部导航栏顺序
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
        case .chatgpt:
            return "ChatGPT"
        case .aistudio:
            return "AIStudio"
        }
    }

    var tabIconSystemName: String {
        switch self {
        case .chatgpt:
            return "globe"
        case .aistudio:
            return "sparkles"
        }
    }

    var preferredContentMode: WKWebpagePreferences.ContentMode {
        switch self {
        case .aistudio:
            // AI Studio 仅有桌面版，强制桌面模式渲染
            return .desktop
        case .chatgpt:
            return .mobile
        }
    }

    var userAgentOverride: String? {
        switch self {
        case .chatgpt:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        case .aistudio:
            // AIStudio 使用手机 UA，确保移动端正常渲染
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
                  console.log('💥 Injected: sidebar-expanded-state set to false BEFORE hydration');
                } catch (e) {
                  console.log('⚠️ Failed to set sidebar state early:', e);
                }
                """,
                documentEnd: """
                var meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1.0';
                document.head.appendChild(meta);
                """,
                didFinish: """
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
            )
        case .aistudio:
            // AI Studio 桌面版：注入 viewport 让页面缩放适配手机屏幕宽度
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
        case .chatgpt:
            return "zoomScale.chatgpt"
        case .aistudio:
            return "zoomScale.aistudio"
        }
    }

    var websiteDataDomain: String {
        switch self {
        case .chatgpt:
            return "chatgpt.com"
        case .aistudio:
            return "aistudio.google.com"
        }
    }
}