---
status: approved
updated: 2026-09-30
---

# Homebrew Tap

## Overview

Publish AmbientSync through the public `fridaypatrick/homebrew-tap` repository so users can install it with:

```sh
brew install --cask fridaypatrick/tap/ambientsync
```

## Requirements

- Seed `Casks/ambientsync.rb` from the published `v0.2.0` arm64 DMG and its verified SHA-256.
- Preserve the existing cask app metadata, macOS requirements, and uninstall behavior from `scripts/update-cask.sh`.
- Replace the existing same-repository cask release update with an update to the external tap's default branch.
- Use the GitHub Actions secret `HOMEBREW_TAP_TOKEN` with contents read/write permissions scoped only to `fridaypatrick/homebrew-tap`. Never fall back to the same-repository `github.token` for external pushes.
- Preserve existing downgrade prevention, checksum validation, and idempotency.
- Fail clearly if the secret is missing or the push is blocked, and leave the published release intact.
- Keep app release assets and the homepage pointing to `fridaypatrick/ambient-sync`.
- Replace the README Homebrew command and document maintainer token setup.

## Acceptance Criteria

- The public tap holds a valid `v0.2.0` cask with SHA-256 `0dc03075ab660cd6153d4ad507122a444cda104f316e48aec1c4db1689d213e1` and the correct DMG URL.
- Homebrew resolves `fridaypatrick/tap/ambientsync` and downloads and checks the artifact without installing the app.
- The workflow targets the external tap, uses the scoped secret, and preserves the existing safeguards.
- The README gives the exact command `brew install --cask fridaypatrick/tap/ambientsync` and documents maintainer setup.
- Static/shell and cask validation pass. Live release-driven update validation remains pending the next release unless safely tested without publishing.

## Out of Scope

- Architecture or legacy `DESIGN.md` migration.
- Release republishing.
- Actual application installation or uninstallation.
- Intel builds.
- Unrelated app changes.
- Token values in files or chat.

## Open Questions

There are no open questions for the implementation scope. Activation requires the user to provision `HOMEBREW_TAP_TOKEN` outside chat.
