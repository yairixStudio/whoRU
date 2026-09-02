# Porting whoRU to another platform

whoRU is split so that a port to Windows or Linux is a bounded piece of work rather than a rewrite. This document describes the boundary and what a port has to provide.

## The split

```
Sources/
  WhoRUCore/      platform-agnostic: models, parser, scoring, headlines, analyst, store, settings
  WhoRUMac/       macOS: dialog watcher, resolver strategies, evidence checks, UI
  whoru/          macOS app entry point
  whoru-cli/      command-line front end (macOS today; core parts compile anywhere)
```

`WhoRUCore` imports Foundation only. It never imports AppKit, SwiftUI, Security or any Apple-specific framework. It builds on Linux and Windows with the Swift toolchain (URLSession comes from `FoundationNetworking` there, which the core handles with a conditional import).

Everything platform-specific is reached through protocols declared in the core. A port implements those protocols in a new module, say `WhoRUWindows`, and provides its own app shell and UI.

## What the core provides

- **Models**: `PermissionPrompt`, `PermissionService`, `Subject`, `EvidenceItem`, `EvidenceBundle`, `HardScore`, `Verdict`, `ScanRecord`.
- **`PromptParser`**: turns dialog text into a requester name and a service, driven by pattern tables that a port extends with its own dialog wording (UAC, consent prompts, portal dialogs).
- **`Collector`**: runs any set of `EvidenceCheck`s in parallel with per-check timeouts and streams results.
- **`HardScoreEngine`**: red / amber / green from normalized evidence facts. The fact keys are platform-neutral (`signer.kind`, `signature.valid`, `download.source`, `location.class`, …).
- **`HeadlineComposer`**: the deterministic headline shown before, or instead of, the model.
- **`Analyst`** protocol with the Claude API implementation, the JSON schema for verdicts, and the `VerdictValidator` that enforces the hard-score rules in code.
- **`ScanStore`** protocol and a JSON-file implementation, keyed by a `Paths` provider so a port decides where data lives.
- **`Settings`** model and `SecretStore` protocol (Keychain on macOS; DPAPI or the credential manager on Windows).
- **`Publishers`**: the built-in publisher list. Team IDs are Apple-specific, so a port adds its own identity type (for example Authenticode subject + thumbprint) behind the same lookup.

## What a port has to implement

| Core protocol | macOS implementation | Windows equivalent (sketch) |
|---|---|---|
| `DialogWatcher` | Accessibility observer on `UserNotificationCenter` windows | UI Automation on consent.exe / UAC secure desktop is not observable; watch app-level consent dialogs (camera/mic/location prompts from the Settings broker) or the Windows Privacy toasts |
| `ProcessInspector` | `libproc`, `NSWorkspace.runningApplications` | `CreateToolhelp32Snapshot`, `QueryFullProcessImageName` |
| `EvidenceCheck` set | `SecStaticCode`, `spctl`, `xattr`, `mdls`, Info.plist, LaunchAgents | Authenticode (`WinVerifyTrust`), SmartScreen / Mark-of-the-Web (Zone.Identifier ADS), `VERSIONINFO` resource, Run keys and scheduled tasks |
| `RequesterResolver` strategies | running process basename, running app name, helper → parent, Launch Services, Spotlight | running process name, `AppxPackage` display name, Start-menu shortcut targets, Windows Search |
| `SecretStore` | Keychain | Credential Manager |
| `Paths` | `~/Library/Application Support/whoRU` | `%LOCALAPPDATA%\whoRU` |
| Companion panel | `NSPanel` + SwiftUI, Liquid Glass | WinUI 3 with Mica / Acrylic, topmost non-activating window |

The `Analyst`, the prompt, the verdict schema, the validator, the store and the history model need no changes.

## Practical steps

1. Add a new target in `Package.swift` next to `WhoRUMac` and gate it with `.when(platforms: [.windows])`.
2. Implement `ProcessInspector` and two or three evidence checks first. Run them through `whoru-cli scan`, which already works without a GUI. That gives you a working verdict pipeline before any UI exists.
3. Add dialog fixtures for your platform’s wording to `Tests/WhoRUCoreTests/Fixtures/` and extend the pattern table.
4. Only then build the watcher and the panel.

Open an issue titled `port: <platform>` before you start. We will label it and help with the core side.
