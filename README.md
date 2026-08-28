# PromptPaste for macOS

PromptPaste is a menu-bar utility that applies AI actions to text selected in another macOS application. It is a native Swift/AppKit/SwiftUI port of the GNOME PromptPaste workflow.

## Features

- Correct, rewrite, and prompt actions for the current selection.
- Unlimited custom actions with enable/disable, ordering, prompt variables, and provider/model overrides.
- `${selection}`, `${language}`, `${tone}`, and `${style}` prompt variables.
- Preview before replacement, copy-result support, automatic replacement, and a time-limited undo action.
- Native floating action palette and menu-bar status item.
- PopClip-style selection button with per-application exclusions.
- Configurable global shortcuts.
- Accessibility selection access with clipboard-copy fallback.
- Clipboard preservation/restoration during fallback capture and replacement where macOS permits it.
- Keychain-backed provider credentials.
- Ollama plus Groq, Cloudflare Workers AI, Gemini, OpenRouter, Cerebras, OpenAI, and Vercel AI Gateway providers.
- Provider-specific request formats, model catalog support, HTTP/error handling, and response-truncation detection.

## Requirements

- macOS 13 Ventura or newer.
- Xcode 16 or newer to build locally.
- Accessibility permission for PromptPaste. AI providers additionally require their own network credentials, except for a local Ollama server.

## Accessibility permission

PromptPaste uses macOS Accessibility APIs to read selected text and replace it directly when the focused application exposes the standard text-element attributes. If direct access is unavailable, it can use a simulated Copy/Paste fallback. Enable **System Settings → Privacy & Security → Accessibility → PromptPaste** and relaunch the app after granting permission.

The fallback detects clipboard changes using `changeCount` polling rather than relying on a single fixed sleep. It snapshots the existing clipboard and restores it after capture/replacement when possible. Some applications do not expose editable selections or refuse synthetic events; those applications may require enabling the fallback or manually pasting the generated result.

## Build

```sh
xcodebuild \
  -project PromptPaste.xcodeproj \
  -scheme PromptPaste \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The unsigned application is produced under `build/` only if you choose that derived-data path; otherwise Xcode places it under its standard DerivedData directory. Open `PromptPaste.xcodeproj` in Xcode for normal development, signing, and local test execution.

GitHub Actions builds and tests the project on a macOS 14 runner and uploads an unsigned `.zip` artifact for each successful build.

## Usage

1. Build and launch PromptPaste.
2. Grant Accessibility access when prompted.
3. Open Settings from the menu-bar item.
4. Choose a provider, configure its model and credential, and review the default/custom actions.
5. Select text in Safari, Firefox, Chrome, VS Code, a text editor, or another accessible application.
6. Invoke an action using its configured shortcut or open the action palette.
7. If preview is enabled, inspect the result and choose **Replace**, **Copy**, or **Cancel**.
8. After an automatic replacement, **Undo Last Replacement** is available for the short undo window configured by the app.

## Providers

Credentials are never written to UserDefaults or project files. API keys and tokens are stored in the macOS Keychain. Requests are sent directly from PromptPaste to the selected provider endpoint. Ollama uses its local HTTP endpoint and does not require a credential. Provider endpoints, model names, account identifiers, token limits, and related options are configurable in Settings where required by the provider.

## Configuration

Settings include the default provider and model, provider-specific configuration, credential management, enabled and ordered custom actions, action prompt/input mode, provider/model overrides, preview behavior, clipboard fallback behavior, floating-button app exclusions, input/output token limits, prompt variables, and shortcut recording.

Normal preferences are stored using macOS preferences (`UserDefaults`). Secrets use Keychain Services. Removing a credential from Settings deletes that Keychain item.

## Privacy

PromptPaste does not operate a hosted relay. Selected text is sent to the provider you choose when an AI action runs. Review the provider's terms and retention policy before using confidential material. Clipboard fallback temporarily reads and writes the general pasteboard in order to capture or replace text; it attempts to restore previous contents afterward.

## macOS limitations

macOS has no GNOME-style PRIMARY selection. PromptPaste therefore prefers Accessibility APIs and provides a copy-based fallback. Accessibility behavior varies between applications, secure text fields, browser pages, remote desktops, and sandboxed apps. Global shortcuts and synthetic keyboard events also require Accessibility permission and can be blocked by the target application. These are platform constraints rather than silently ignored features.

## License

PromptPaste is distributed under the GNU General Public License, version 3 or later. See [LICENSE](LICENSE).
