# Contributing to whoRU

Thank you for considering a contribution. whoRU is small, opinionated, and built to be easy to work on. This document tells you what we are looking for, what we will not merge, and how a change goes from an idea to `main`.

## What we are looking for

In rough order of how much they help right now:

1. **Dialog fixtures in more languages.** whoRU parses the text of macOS permission dialogs. English is covered; every other language needs real samples. See [Dialog fixtures](#dialog-fixtures) below. No Swift required.
2. **Evidence checks.** Each check is one file that runs a deterministic command or system API and returns a normalized result. Ideas: Homebrew cask manifests, App Store receipts, login items, XPC helpers.
3. **Verified publishers.** Team IDs of well-known publishers, taken from a real code signature (`codesign -dv --verbose=2 /Applications/X.app`), not from memory.
4. **Bug reports with a reproducible dialog.** Which app, which permission, what whoRU showed, what it should have shown.
5. **Tests.** Especially for the parser, the resolver and the hard score.
6. **Ports.** The core is platform-agnostic Swift. A Windows or Linux port lives in its own `Sources/WhoRU<Platform>` module and reuses everything in `WhoRUCore`. See [docs/PORTING.md](docs/PORTING.md).
7. **Documentation and translations** of the app strings.

## What we will not merge

These are the rules, not preferences. They exist because whoRU asks for a powerful permission and has to earn it.

- **Anything that clicks, types or answers a dialog on the user’s behalf.** Not as a feature, not as an option, not behind a flag.
- **Anything that sends file contents off the machine.** Only names, paths (username redacted), signatures, hashes and metadata may leave. The AI layer gets a JSON bundle, never bytes of the file.
- **Telemetry, analytics or crash reporting** that phones home without an explicit opt-in screen.
- **Changes that let the model override hard evidence.** A red hard score stays red. The validator that enforces this is not optional.
- **Code that modifies the system.** No hooks, no code injection, no SIP changes, no kernel or system extensions.
- **New third-party dependencies** without a discussion first. The app currently has none, on purpose.
- **A free shell for the model.** Tools the model can call are a closed list, implemented in code, with validated inputs. An engine that brings its own shell (Claude Code) gets exactly one command, `whoru-inspect`, which takes a subcommand and nothing else; do not widen its allowlist.
- **An engine that inherits whoRU’s permissions.** Every child process that whoRU does not control runs disclaimed, as its own responsible process. A new engine must be spawned the same way.

If you are unsure whether an idea fits, open an issue before writing code. That is faster for both of us.

## How to contribute

### Small changes

Fixtures, typos, a verified publisher, a test: just open a pull request.

### Larger changes

Open an issue first and describe what you want to change and why. This avoids the situation where you spend a weekend on something that cannot be merged. We usually answer within a few days.

### Pull requests

- One change per pull request. Small is good.
- Add or update tests for anything in `WhoRUCore`.
- `swift build` and `swift test` must pass. CI runs both.
- Write the commit message in the imperative with a type prefix: `feat(core): …`, `fix(mac): …`, `docs: …`, `test: …`, `build: …`, `chore: …`.
- Fill in the pull request template. Reviewers read it.

### Code style

- Swift 6 language mode in `WhoRUCore`, strict concurrency. Everything crossing an actor boundary is `Sendable`.
- Platform code lives in `WhoRUMac` (or a sibling module for another platform). The core never imports AppKit, SwiftUI or any platform framework.
- Prefer a system API over parsing command output. When you do call a command, pass arguments as an array, never as a shell string. Dialog text is hostile input.
- `swiftlint` runs in CI with the config in the repository.
- Comments explain *why*, not *what*.
- English for code, comments, commit messages and documentation.

## Dialog fixtures

The parser learns each language from real dialog text. To contribute a fixture:

1. Trigger a permission dialog in your language (for example, open an app that asks for the Downloads folder for the first time, or reset a permission with `tccutil reset SystemPolicyDownloadsFolder <bundle id>` and launch the app again).
2. Copy the title line and the body line exactly. A screenshot helps but the text is what we need.
3. Add a case to `Tests/WhoRUCoreTests/Fixtures/dialogs.<lang>.json`:

```json
{
  "title": "“Google Chrome” would like to access files in your Downloads folder.",
  "body": "Chrome needs this to save downloaded files.",
  "expected": { "requester": "Google Chrome", "service": "downloadsFolder" }
}
```

4. Run `swift test`. If the parser does not handle it yet, that is fine: open the pull request anyway and mark the case `"pending": true`. A failing fixture is still valuable.

## Reporting a security issue

Please do not open a public issue. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE), the same as the rest of the project.
