import Foundation

struct InjectedJavaScript {
    let documentStart: String?
    let documentEnd: String?
    let didFinish: String?
}

enum Service: CaseIterable {
    // 底部导航栏顺序
    case chatgpt
    case aistudio
    // case claude
    // case grok

    var homeURL: URL {
        switch self {
        case .chatgpt:
            return URL(string: "https://chatgpt.com/")!
        case .aistudio:
            return URL(string: "https://aistudio.google.com/prompts/new_chat")!
        // case .claude:
        //     return URL(string: "https://claude.ai/")!
        // case .grok:
        //     return URL(string: "https://grok.com/")!
        }
    }

    var title: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .aistudio:
            return "AIStudio"
        // case .claude:
        //     return "Claude"
        // case .grok:
        //     return "Grok"
        }
    }

    var tabIconSystemName: String {
        switch self {
        case .chatgpt:
            return "globe"
        case .aistudio:
            return "sparkles"
        // case .claude:
        //     return "pencil"
        // case .grok:
        //     return "bolt.horizontal.circle"
        }
    }

    var userAgentOverride: String? {
        switch self {
        case .chatgpt, .aistudio: 
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        // case .aistudio, .claude: 
            // 只有 AI Studio claude 老老实实当手机
            // return nil
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
        // case .grok:
        //     //  Grok 缩放代码，强行压缩回手机大小
        //     return InjectedJavaScript(
        //         documentStart: nil,
        //         documentEnd: """
        //         var meta = document.createElement('meta');
        //         meta.name = 'viewport';
        //         meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        //         document.head.appendChild(meta);
        //         """,
        //         didFinish: nil
        //     )
        // case .aistudio, .claude:
        //     // AI Studio claude 不需要特殊处理
        //     return nil
        }
    }

    var zoomDefaultsKey: String {
        switch self {
        case .chatgpt:
            return "zoomScale.chatgpt"
        case .aistudio:
            return "zoomScale.aistudio"
        // case .claude:
        //     return "zoomScale.claude"
        // case .grok:
        //     return "zoomScale.grok"
        }
    }

    var websiteDataDomain: String {
        switch self {
        case .chatgpt:
            return "chatgpt.com"
        case .aistudio:
            return "aistudio.google.com"
        // case .claude:
        //     return "claude.ai"
        // case .grok:
        //     return "grok.com"
        }
    }
}