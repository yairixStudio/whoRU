# Security

whoRU inspects programs that ask for permissions. That makes the tool itself a target, and it holds an Accessibility permission. The AI engines it runs are separate processes that hold none of its permissions, and the only command it hands them is `whoru-inspect`. We take reports seriously.

## Reporting a vulnerability

Please use GitHub’s private vulnerability reporting on this repository (Security → Report a vulnerability). Do not open a public issue for anything that could be exploited.

Include what you can:

- The version or commit you tested.
- Steps to reproduce, or a proof of concept.
- What an attacker gains.

You will get an acknowledgement within a few days and a fix or a mitigation plan as soon as we have one. We will credit you in the release notes unless you prefer otherwise.

## What is in scope

- Ways to make whoRU show a wrong verdict for a malicious program (for example, evading the impersonation check, the signature verification, the revocation check or the running-process check).
- Forging a system dialog: a window that whoRU accepts as a macOS permission dialog although it was not drawn by one of the platform’s own dialog processes. One case is known and is not a report: any program can ask macOS to display an alert, and macOS draws it with the process, and the look, of a real permission prompt. whoRU cannot tell that window apart by inspecting it, so it relies on the system’s record of the request and reports *not confirmed* when there is none. A way to make whoRU call such an alert confirmed, or to keep it from reporting an unconfirmed one, is in scope.
- Defeating identity confirmation: making whoRU confirm, from the system log, a program other than the one the system held responsible, or making it scan the wrong program without saying *not confirmed*.
- Escaping `whoru-inspect`: getting an AI engine to run any other command, to point the shim at a file other than the subject, or to reach whoRU’s permissions from the engine’s process.
- Prompt injection through app metadata (the `claims` object, or anything else the program wrote) that changes the model’s verdict beyond what the hard-score validator allows.
- Defeating the store integrity check: changing `settings.json` or `publishers.json` from outside whoRU without the change being noticed and the file ignored.
- Command injection through dialog text, file names or paths.
- Leaking file contents, file names or secrets (API keys, the store integrity key) off the machine.
- Anything that lets a third party use whoRU’s Accessibility permission, including through a program whoRU runs.

## What whoRU does not promise

- It is not an antivirus and does not claim to detect all malware.
- A green verdict is about identity, not behaviour. It means the evidence is consistent with a legitimate program from the stated publisher: the signature is valid, the system attributes the request to that program, and the process in memory is the file on disk. A signed and notarized program can still be malicious, or compromised upstream. *Safe to allow* appears only for a byte-for-byte match with the publisher’s official release, and that check exists today for one product.
- The integrity sidecars on the settings and trust-list files are tamper evidence, not confidentiality. The files stay plain JSON and can be read by any process running as the user.
- whoRU cannot prove a window is a genuine permission prompt. It can prove one is not (the wrong process drew it), and it can confirm a genuine one when the system recorded the request. A prompt it could not confirm is shown as unconfirmed, and under *strict* it cannot be green.
