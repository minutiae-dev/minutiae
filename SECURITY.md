# Security policy

Minutiae runs entirely on your Mac. It has no server, no account and no
telemetry; the only network traffic is downloading models from Hugging Face.
Security issues are therefore about what the app does locally: recording
without consent, writing outside the folders you chose, handling of
permissions, or unsafe parsing of files and messages.

## Reporting

Please do not open a public issue for a vulnerability. Use GitHub's private
reporting at
<https://github.com/minutiae-app/minutiae/security/advisories/new>. Include
the macOS version, the app version, and steps to reproduce.

You will get an acknowledgement within a week. Fixes ship in the next release
and the advisory is published once it does.

## Scope

- The app (`app/`), the audio engine (`engine/`), the LLM sidecar
  (`llm-engine/`) and the build scripts in this repository.
- The closed cloud tier is not in this repository and is out of scope here.
