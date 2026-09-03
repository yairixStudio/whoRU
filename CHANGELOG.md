# Changelog

All notable changes to whoRU. Dates are the release date; versions follow
[semantic versioning](https://semver.org), and while the major version is 0 a
minor bump may change behaviour.

## 0.2.0 — 2026-09-03

A security release. An outside review of 0.1.0 found two structural problems and
a list of smaller ones. This version closes them, and states plainly the one case
that cannot be closed.

### The dialog itself is now checked

- A window is treated as a permission dialog only when its owner is one of
  macOS's own dialog processes **and** is Apple platform code. A window a program
  drew itself now gets a red *Not a system dialog* panel naming that program and
  its signer, and is never scanned.
- **Known limitation, stated on purpose.** Any program can ask macOS to display
  an alert, and macOS draws it with the same process, and the same appearance,
  it uses for a genuine permission prompt. Nothing in that window distinguishes
  it. whoRU falls back on the system's own record of the request, and when that
  record is missing it says so instead of vouching for the dialog. See below.

### The requester is confirmed by the system, not guessed from the wording

- whoRU reads the system's own record of the request, which names the responsible
  process with its process id and path. That record confirms the resolver's
  answer, corrects it (the scan is redone for the program the system named), or
  is absent.
- An absent record is now a finding, not a footnote. The score carries an
  `identity.unconfirmed` concern, the panel shows a warning that explains what it
  means, the model is told the same, and under *strict* the scan cannot be green.
- Two programs with the same name are an amber collision, listed in the panel
  under *Also matches*, until the system says which one asked.
- Once the requester is confirmed, the running process is validated: its dynamic
  code signature, and its code directory hash against the file on disk. A
  mismatch is red, and a verdict formed before that evidence arrived is withdrawn.
  A process that has exited, or whose process id was reused, is reported as
  inconclusive and never turns a scan red.

### The programs whoRU runs hold none of its permissions

- Every AI engine is spawned as its own responsible process, so it inherits
  nothing from whoRU, its Accessibility grant included.
- Claude Code is verified before every use (Anthropic's Developer ID, hardened
  runtime) and runs with no user settings, hooks, MCP servers or slash commands.
- Its only command is `whoru-inspect`, a small tool inside the app that inspects
  the program under review and nothing else.

### Scoring

- A revoked signing certificate is red. New revocation check, with revocation
  enforced.
- When Gatekeeper rejects a program, only Apple's own signature or a
  byte-for-byte match with the publisher's official release can still be green.
- The model can never recommend *allow* on an amber score or with an *unknown*
  verdict.

### Privacy and integrity

- Everything a program wrote about itself reaches the model once, in a `claims`
  object marked as its own claims. Usage descriptions are no longer quoted inside
  evidence rows.
- The tool that reports a program's open files returns folders and a count, never
  file names.
- *What was sent?* now also lists the tools the model called and what came back.
- `settings.json` and the publisher trust list carry a signature. A file changed
  outside whoRU is ignored and a banner in Settings says so. A trust list with no
  signature is not honoured once a key exists.

### Interface

- The companion panel can be pinned so it stays after the dialog closes, and a
  panel dragged aside stays where it was put.

### Fixed

- The command-line tool no longer reads the app's Keychain item, which used to
  put a Keychain dialog on screen and block a scan.
- Log lines written before the log file is opened are kept.

## 0.1.0 — 2026-09-02

First working version: dialog watcher and companion panel, requester resolver,
parallel evidence checks with a deterministic red / amber / green score, optional
AI analysts bound by that score, onboarding, settings, history, the command-line
scanner, and a signed and notarized installer package.
