# Architecture

whoRU is one process: a menu-bar app that watches for permission dialogs and runs a scan pipeline. This page is the map for someone who wants to change something.

## Modules

```
Sources/
  WhoRUCore/      Foundation only. Builds anywhere Swift builds.
    Models/       PermissionPrompt, Subject, EvidenceItem, HardScore, Verdict, EvidenceBundle
    Parsing/      PromptParser: dialog text → requester + service
    Resolver/     RequesterResolver: name → file, through ProcessInspector / ApplicationFinder
    Evidence/     EvidenceCheck protocol, Collector, derivations, core checks (SHA-256, manifest, VirusTotal)
    Scoring/      HardScoreEngine, HeadlineComposer, VerdictPresentation
    Analyst/      Analyst protocol, Claude API, Claude Code, local model, prompt, schema, validator, tools
    Scan/         ScanPipeline: resolve → collect → score → cache | skip | analyze → validate → store
    Store/        ScanRecord, ScanStore protocol, JSON file store
    Settings/     Settings, SettingsStore, SecretStore, Paths
    Publishers/   Publisher directory and the built-in list
    Platform/     Protocols a platform implements; BundleInfo (portable plist reader)
    Support/      JSONValue, Command (argument arrays only), timeouts, portable SHA-256
  WhoRUMac/       macOS implementations
    Watcher/      AXDialogWatcher (Accessibility observer + poll fallback)
    Platform/     MacProcessInspector (libproc + NSWorkspace), MacApplicationFinder, Keychain, AccessibilityPermission
    Checks/       CodeSignature (SecStaticCode, shared cache), signature/gatekeeper/entitlements, file checks
    MacTools      the closed tool set the model may call
    MacEnvironment assembles a ScanEnvironment; verifies the Claude Code binary
  whoru/          the app: AppDelegate, AppModel, ScanSession, CompanionPanel/View, menu, onboarding, settings, history
  whoru-cli/      the same pipeline from a terminal
```

Dependency direction is strict: `whoru` → `WhoRUMac` → `WhoRUCore`. The core never imports a platform framework, and every platform-specific capability is a protocol declared in the core.

## One scan, step by step

1. **Watcher** (`AXDialogWatcher`) sees a new window in `UserNotificationCenter`, reads its static texts, buttons and frame, and yields `DialogEvent.appeared`.
2. **AppModel.startScan** parses the title with `PromptParser`. No match: the panel shows the raw text and offers a manual scan. Match: a `ScanSession` is created and `ScanPipeline.run` starts.
3. **Resolver** turns the name into a `Subject` (path, pid, bundle) with a confidence, keeping every candidate.
4. **Collector** runs the fast checks in a task group with a 4-second deadline each, streaming `EvidenceItem`s to the session as they finish. Each check emits normalized `facts` (`signer.kind`, `signature.valid`, `manifest.match`, …) that the scoring engine reads; the raw output is kept for “How did you check?”.
5. **Derivations** run once the checks are in: publisher lookup from the Team ID, impersonation (name vs. signer), history.
6. **HardScoreEngine** produces red / amber / green with ordered reasons. **HeadlineComposer** renders the first reason as a title and a sentence. The panel shows this at about one second; it is the final answer when there is no model.
7. **Short-circuits**: cached verdict for the same hash and permission (30 days), Apple-signed system component, trusted publisher, local-only mode, no engine, budget reached.
8. **Analyst** gets the redacted `EvidenceBundle` (home directory replaced by `~`, raw output dropped) and returns a `Verdict` through a JSON schema. The Claude API engine streams; the `headline` field is surfaced as soon as it closes. Tool calls go through `ToolRegistry`, a closed list with validated inputs.
9. **VerdictValidator** enforces the contract in code: red cannot become legitimate or “allow”; amber caps at probably-legitimate at 75; citations of nonexistent evidence become inferences.
10. **Store** writes one JSON file per scan. Slow checks (network connections, VirusTotal) run afterwards and update the record.
11. When the dialog closes, the panel asks what the user chose (unless Full Disk Access lets a later version read it) and fades, or turns into a normal window if a conversation is going on.

## Where to add things

| I want to… | Touch |
|---|---|
| Support dialog wording in another language | `Tests/WhoRUCoreTests/Fixtures/dialogs.<lang>.json`, then `PromptParser.builtinPatterns` |
| Add an evidence check | One file in `WhoRUMac/Checks/` (or `WhoRUCore/Evidence/CoreChecks.swift` if it only needs the network), conforming to `EvidenceCheck`; register it in `MacEnvironment.checks()`; emit facts from `Fact` |
| Change what makes something red or green | `HardScoreEngine` and its truth table in `HardScoreTests` |
| Add a verified publisher | `BuiltinPublishers` with the `codesign` output in the PR |
| Add a tool the model may call | `MacTools` (or `CoreTools`), keep inputs validated and scoped to the subject |
| Add an AI engine | Conform to `Analyst`; wire it in `MacEnvironment.analyst` |
| Change the panel | `whoru/Panel/CompanionView.swift`; positioning and window behavior in `CompanionPanel.swift` |
| Port to another OS | See `PORTING.md` |

## Concurrency

The core is Swift 6 with strict concurrency; everything that crosses a task boundary is `Sendable`. `Collector` and `ScanPipeline` are plain structs that spawn task groups. The signature cache is an actor that coalesces concurrent inspections of the same path. UI state (`AppModel`, `ScanSession`) is `@MainActor` and `@Observable`; pipeline events are hopped to the main actor in `AppModel.run`.

## Security boundaries

- Commands run through `Command.run(executable, [arguments])`. There is no API that takes a shell string.
- The model receives a JSON bundle, never file bytes. Fields written by the program under review are listed in `hostileFields`.
- Tool handlers receive the scan's `Subject`; the model cannot name a path.
- `VerdictValidator` runs after every model answer. The prompt asks; the code enforces.
- Secrets live in the Keychain (`KeychainSecretStore`); the environment store is read-only and exists for the command line and CI.
