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
    Analyst/      Analyst protocol, Claude API, Claude Code, Codex, Gemini, Apple Intelligence, local model, prompt, schema, validator, tools
    Scan/         ScanPipeline: resolve → collect → score → cache | skip | analyze → validate → store
                  IdentityConfirmation: reconciles a record with the system's own attribution of the request
    Store/        ScanRecord, ScanStore protocol, JSON file store
    Settings/     Settings, SettingsStore (signed settings.json), SecretStore, Paths
    Publishers/   Publisher directory, the built-in list, PublisherOverridesStore (signed publishers.json)
    Platform/     Protocols a platform implements; DialogOrigin; BundleInfo (portable plist reader)
    Support/      JSONValue, Command (argument arrays only, disclaimed children), FileIntegrity (HMAC sidecars), timeouts, portable SHA-256
  WhoRUMac/       macOS implementations
    Watcher/      AXDialogWatcher (window list + Accessibility, decides who drew the window), IdentityLookup and TCCDecisionLookup (tccd's log)
    Platform/     MacProcessInspector (libproc + NSWorkspace), MacApplicationFinder, ProcessTrust (platform signature of a pid), Keychain, AccessibilityPermission
    Checks/       CodeSignature (SecStaticCode, shared cache), signature/gatekeeper/revocation/entitlements, file checks, RunningCode (process vs. file on disk)
    MacTools      the closed tool set the Claude API engine may call
    MacEnvironment assembles a ScanEnvironment; verifies the Claude Code binary
  whoru/          the app: AppDelegate, AppModel, ScanSession, CompanionPanel/View, menu, onboarding, settings, history
  whoru-cli/      the same pipeline from a terminal
  whoru-inspect/  the one command an AI engine may run: fixed inspections of the program under review
```

Dependency direction is strict: `whoru` → `WhoRUMac` → `WhoRUCore`. The core never imports a platform framework, and every platform-specific capability is a protocol declared in the core.

## One scan, step by step

1. **Watcher** (`AXDialogWatcher`) sees a new alert-shaped window in the on-screen window list, reads its static texts, buttons and frame through Accessibility, and yields `DialogEvent.appeared` with a `DialogOrigin`. The origin is `.system` only when the window's owner is one of the known dialog processes (`UserNotificationCenter`, `CoreServicesUIAgent`, `SecurityAgent`) *and* satisfies `anchor apple` (`ProcessTrust`). Anything else is `.unverified`, with the owner's executable path and signer.
2. **AppModel.startScan** parses the title with `PromptParser`. No match: the panel shows the raw text and offers a manual scan. Match with an unverified origin: the session is marked red with the reason `dialog.fake`, the headline reads *Not a system dialog*, the evidence rows say who drew the window and who signed it, and nothing else runs: no pipeline, no model, no decision lookup. Match with a system origin: a `ScanSession` is created and `ScanPipeline.run` starts.
3. **IdentityLookup** starts in parallel with the pipeline, once per dialog. It runs `log show` for `tccd`'s `AUTHREQ_*` lines since ten seconds before the dialog, on a schedule of seven looks over about 17 seconds, and returns the `responsible` process (pid, binary path, identifier) of the most recent request for that permission, preferring one the system prompted for. No lines is a normal outcome and is never waited on.
4. **Resolver** turns the name into a `Subject` (path, pid, bundle) with a confidence, keeping every candidate.
5. **Collector** runs the fast checks in a task group with a 4-second deadline each, streaming `EvidenceItem`s to the session as they finish. Each check emits normalized `facts` (`signer.kind`, `signature.valid`, `signature.revoked`, `manifest.match`, …) that the scoring engine reads; the raw output is kept for “How did you check?”. Usage descriptions go into facts only, never into a summary.
6. **Derivations** run once the checks are in: publisher lookup from the Team ID, impersonation (name vs. signer), history.
7. **HardScoreEngine** produces red / amber / green with ordered reasons. Red: broken signature, revoked certificate, running code invalid or not the file on disk, impersonation, VirusTotal, blocked publisher. Amber includes a collision (more than one confident candidate while identity is unconfirmed) and a Gatekeeper rejection, which leaves only `signed.apple` and `manifest.match` standing as green. **HeadlineComposer** renders the first reason as a title and a sentence. The panel shows this at about one second; it is the final answer when there is no model.
8. **Short-circuits**: cached verdict for the same hash and permission (30 days), Apple-signed system component, trusted publisher, local-only mode, no engine, budget reached.
9. **Analyst** gets the redacted `EvidenceBundle` (home directory replaced by `~`, raw output dropped, program-authored text moved into `claims`) and returns a `Verdict` through a JSON schema. The Claude API engine streams; the `headline` field is surfaced as soon as it closes. Its tool calls go through `ToolRegistry`, a closed list with validated inputs. Claude Code gets a single command instead, `whoru-inspect`. Every engine runs disclaimed (see Security boundaries).
10. **VerdictValidator** enforces the contract in code: red cannot become legitimate or “allow”; amber caps at probably-legitimate at 75 and turns “allow” into “investigate”; “unknown” never comes with “allow”; citations of nonexistent evidence become inferences.
11. **IdentityConfirmation** runs as soon as the record exists, while the slow checks are still out, with whatever the lookup returned. Three outcomes. *Confirmed*: the attribution names the scanned program (same bundle identifier, same file, or a file inside the bundle); `RunningCode.validate` compares the process in memory (dynamic `SecCodeCheckValidity`, code directory hash) with the file on disk; the record gains `identity` and `running_code` evidence, is re-scored and gets a fresh headline; a verdict that said legitimate or “allow” on what is now red is withdrawn. *Corrected*: the attribution names a different program; the session is reset and scanned again for that subject, once. *Unconfirmed*: nothing changes and the panel says so. The same reconciliation is applied again to the merged record after the slow checks.
12. **Store** writes one JSON file per scan. Slow checks (network connections, VirusTotal) run afterwards and update the record.
13. When the dialog closes, the panel reads the decision from the system log (or asks), and fades, unless it is pinned or a conversation is going on, in which case it stays as a normal window.

## Where to add things

| I want to… | Touch |
|---|---|
| Support dialog wording in another language | `Tests/WhoRUCoreTests/Fixtures/dialogs.<lang>.json`, then `PromptParser.builtinPatterns` |
| Add an evidence check | One file in `WhoRUMac/Checks/` (or `WhoRUCore/Evidence/CoreChecks.swift` if it only needs the network), conforming to `EvidenceCheck`; register it in `MacEnvironment.checks()`; emit facts from `Fact` |
| Change what makes something red or green | `HardScoreEngine` and its truth table in `HardScoreTests` |
| Add a verified publisher | `BuiltinPublishers` with the `codesign` output in the PR |
| Add a tool the Claude API model may call | `MacTools` (or `CoreTools`), keep inputs validated and scoped to the subject |
| Give Claude Code another inspection | A subcommand in `whoru-inspect/Inspect.swift` with a fixed tool and a fixed argument list; list it in `ClaudeCodeAnalyst.inspectSubcommands` |
| Add an AI engine | Conform to `Analyst`; spawn it with `disclaimResponsibility: true`; wire it in `MacEnvironment.analyst` |
| Change the panel | `whoru/Panel/CompanionView.swift`; positioning and window behavior in `CompanionPanel.swift` |
| Port to another OS | See `PORTING.md` |

## Concurrency

The core is Swift 6 with strict concurrency; everything that crosses a task boundary is `Sendable`. `Collector` and `ScanPipeline` are plain structs that spawn task groups. The signature cache is an actor that coalesces concurrent inspections of the same path. UI state (`AppModel`, `ScanSession`) is `@MainActor` and `@Observable`; pipeline events are hopped to the main actor in `AppModel.run`.

## Security boundaries

- Commands run through `Command.run(executable, [arguments])`. There is no API that takes a shell string. A dialog name that contains Spotlight query syntax (`*`, `?`, quotes, backslashes, control characters) is never passed to `mdfind`.
- A window is a permission dialog only if the process that drew it is a known dialog process by bundle identifier *and* Apple platform code by signature (`ProcessTrust.isApplePlatformProcess`). The owner name and bundle identifier are the process's own claims; the pid from the window server, the path from the kernel and the signature from Security.framework are not.
- The dialog's wording names a program; `tccd`'s log names a process. Identity is confirmed from the log, and the process is compared with the file on disk before the evidence about that file is allowed to stand.
- Children whoRU does not control (the AI engines) are spawned with `disclaimResponsibility: true`: `posix_spawn` with `responsibility_spawnattrs_setdisclaim`, so the child is its own responsible process for TCC and inherits none of whoRU's grants, Accessibility included. stdin is `/dev/null`, all other descriptors are closed. Apple's own tools (`codesign`, `spctl`, `mdls`, `lsof`, `log`) run attributed to whoRU so their file access keeps working.
- Claude Code is checked by `ClaudeCodeVerifier` every time the engine is set up, for an explicit choice as well as the automatic one: a valid Developer ID signature from Anthropic's team with the hardened runtime. Failure means no engine, not a fallback. It runs with `--setting-sources ""`, `--strict-mcp-config` and `--disable-slash-commands`, in an empty scratch directory, with reading, writing, search and fetch tools disallowed, and one allowed Bash command: the `whoru-inspect` shim next to the app binary. The shim takes a subcommand and nothing else; the subject comes from environment variables whoRU sets, and every subcommand is a fixed tool with a fixed argument list on that subject. Codex and Gemini are scripts with no signature to check; they run disclaimed and get no commands.
- The model receives a JSON bundle, never file bytes. Everything the program under review wrote about itself (dialog name, display name, bundle identifier, version, usage descriptions) is collected into `EvidenceBundle.claims`, listed in `hostileFields`, and removed from the evidence rows, so hostile text appears in exactly one place and is labelled there.
- Tool handlers receive the scan's `Subject`; the model cannot name a path. `list_open_files` and `whoru-inspect files` report folders and a count, never file names.
- `VerdictValidator` runs after every model answer. The prompt asks; the code enforces. `IdentityConfirmation` withdraws a verdict when hard evidence turns red after it was given.
- `settings.json` and `publishers.json` are tamper-evident: `FileIntegrity` writes a `.sig` sidecar with an HMAC-SHA256 of the bytes, keyed with a 32-byte secret in the Keychain (`store-integrity-key`). A file whose sidecar does not match is ignored (defaults, or an empty trust list) and `AppModel.integrityWarning` shows a banner in Settings. A file with no sidecar is trusted once and signed on the next save. The command-line tool never creates the key; it verifies when a key is available to it and otherwise uses the file unverified, with a warning when a sidecar is present and does not match.
- Secrets live in the Keychain (`KeychainSecretStore`); the environment store is read-only and exists for the command line and CI.
