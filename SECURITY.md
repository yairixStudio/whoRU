# Security

whoRU inspects programs that ask for permissions. That makes the tool itself a target, and it holds an Accessibility permission. We take reports seriously.

## Reporting a vulnerability

Please use GitHub’s private vulnerability reporting on this repository (Security → Report a vulnerability). Do not open a public issue for anything that could be exploited.

Include what you can:

- The version or commit you tested.
- Steps to reproduce, or a proof of concept.
- What an attacker gains.

You will get an acknowledgement within a few days and a fix or a mitigation plan as soon as we have one. We will credit you in the release notes unless you prefer otherwise.

## What is in scope

- Ways to make whoRU show a wrong verdict for a malicious program (for example, evading the impersonation check or the signature verification).
- Prompt injection through app metadata that changes the model’s verdict beyond what the hard-score validator allows.
- Command injection through dialog text, file names or paths.
- Leaking file contents or secrets (API keys) off the machine.
- Anything that lets a third party use whoRU’s Accessibility permission.

## What whoRU does not promise

- It is not an antivirus and does not claim to detect all malware.
- A green verdict means the evidence is consistent with a legitimate program from the stated publisher. It is not a guarantee about the program’s behaviour.
