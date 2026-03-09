# ChatGPT WebView for iOS 16

A lightweight iOS WebView wrapper for ChatGPT’s web app. Built with Swift and WKWebView, optimized for fast performance and speech-to-text microphone support on iOS 16.

## Features
- Persistent login
- Safari 16+ User-Agent spoofing
- Mic input (speech-to-text)
- Dark mode support
- Per-tab zoom controls with saved per-service zoom
- TrollStore compatibility
- Manual or Xcode install

## Tabs & Service URLs
The app ships with a three-tab UI for ChatGPT, Gemini, and Grok, plus a Notes tab backed
by a native `UITextView` for quick text capture. To point a web tab at a different site,
update the corresponding `homeURL` in the `Service` enum.

## Memory Management
On memory warnings, the app conservatively unloads background web tabs to free resources
while preserving each tab’s last URL and session data so they can reload seamlessly when
reselected.

## Build Requirements
- Xcode 14+
- Target iOS 15-16
- Swift 5.0+

## Installation
1. Open this project in Xcode
2. Choose your device or simulator
3. Hit “Run” to build

## GitHub Actions (unsigned IPA)
An automated workflow builds an unsigned IPA on macOS runners:
- Workflow file: `.github/workflows/unsigned-ipa.yml`
- Project path: `ChatGPTWebView/ChatGPTWebView.xcodeproj`
- Triggers: pushes to `main` or manual `workflow_dispatch`
- Output: `ChatGPTWebView-unsigned.ipa` artifact attached to the run

## App Icon
App icons are stored in the directory:
`ChatGPTWebView/ChatGPTWebView/Assets.xcassets/AppIcon.appiconset/`
Example file:
`ChatGPTWebView/ChatGPTWebView/Assets.xcassets/AppIcon.appiconset/100.png`

The Xcode project uses **manual code signing with an empty Development Team** to avoid
needing any certificates. The workflow also passes `CODE_SIGNING_ALLOWED=NO`, so the
build succeeds on GitHub-hosted runners without provisioning profiles.

## License
MIT
