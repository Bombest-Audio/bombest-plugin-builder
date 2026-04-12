# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo combines two systems:

1. **Plugin Freedom System (PFS)** — an AI-assisted JUCE plugin development platform. Create plugins through conversation: `/dream` → `/plan` → `/implement` → `/improve`. Plugins live in `plugins/`, registered in `PLUGINS.md`.
2. **Bombest Build Framework** — production build/sign/deploy/version infrastructure wrapping CMake + JUCE with S3 distribution. Config in `build.json`.

The `plugins/` directory contains plugin projects (each with their own `CMakeLists.txt` + `Source/`). The root `CMakeLists.txt` scans and builds all of them.

## Git Remotes

- `origin` → `https://github.com/thomasphillips3/bombest-plugin-builder` (push target)
- `upstream` → `https://github.com/glittercowboy/plugin-freedom-system` (pull PFS updates)

To pull upstream PFS changes: `git fetch upstream && git merge upstream/main`

## Build System
- **Framework**: JUCE (v7.x) with CMake
- **Generator**: Ninja (configurable in build.json)
- **Build directory**: `build/`
- **Source**: `src/`, JUCE modules in `libs/JUCE`
- **Config source of truth**: `build.json` (signing identities, S3 bucket, formats, paths)

## Plugin Targets

Formats: VST3, CLAP, AU, AAX, Standalone

Each format produces a separate binary in `build/` after a successful cmake build.

## Build Tiers

| Tier    | Config  | Signing              | Use Case                       |
|---------|---------|----------------------|--------------------------------|
| dev     | Debug   | unsigned             | Local testing, fast iteration  |
| alpha   | Release | ad hoc signed        | Tester distribution            |
| release | Release | full + notarized     | Public distribution            |

## Signing Identities

Configured in `build.json`. The signing identity strings must match your keychain exactly.

- **Ad hoc**: `-` (always available, no certificate needed)
- **Full**: `Developer ID Application: <Name> (<Team ID>)`
- **Installer**: `Developer ID Installer: <Name> (<Team ID>)`

To set up notarization credentials:
```bash
xcrun notarytool store-credentials "notarize-profile" \
  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
```

## S3 Deployment

Builds deploy to a static S3 site. Config in `build.json`.
- Structure: `/<plugin-name>/<tier>/<version>/`
- Each version has a `manifest.json` with metadata
- `latest.txt` per tier points to the most recent version
- `index.html` at the root lists all builds

## Version Source of Truth

- **Primary**: `CMakeLists.txt` → `PROJECT_VERSION` variable
- **Secondary**: `src/PluginInfo.h` → `PLUGIN_VERSION_STRING` define (auto-synced by version script)

## Plugin Freedom System (PFS)

### Plugin Workflow Commands

| Command | Purpose |
|---------|---------|
| `/dream [PluginName]` | Ideate — explore concepts, no implementation |
| `/plan [PluginName]` | Design architecture and parameter spec |
| `/implement [PluginName]` | Stages 1–4: foundation → DSP → UI → validation |
| `/improve [PluginName]` | Enhance a working plugin |
| `/test [PluginName]` | Run quality validation |
| `/package [PluginName]` | Create distribution installers |
| `/setup` | Validate dev environment dependencies |
| `/continue` | Resume from an interruption |
| `/reconcile` | Fix state inconsistencies |

### PFS Agent System

Eight specialized subagents in `.claude/agents/` handle discrete stages: `foundation-shell-agent` (JUCE scaffolding), `dsp-agent` (audio processing), `gui-agent` (low-level UI code), `ui-design-agent` (visual/UX design), `ui-finalization-agent` (polish), `validation-agent` (quality gates), `research-planning-agent`, `troubleshoot-agent`.

### Lifecycle Hooks

Defined in `.claude/settings.json`, run by the Claude Code harness:
- **SessionStart** — validates dev environment (CMake, JUCE, codesign, etc.)
- **PostToolUse** — JUCE best-practice validation after file writes
- **PreCompact** — preserves contract files before context compaction

### Plugin Registry

`PLUGINS.md` is the central state file. Every plugin has a status, stage (0–5), and version. Each plugin directory requires a `NOTES.md` with lifecycle documentation.

### Preferences

`.claude/preferences.json` controls workflow mode:
- `"mode": "express"` — auto-advance stages
- `"mode": "manual"` — show menus at each stage (default)

---

## Bombest Skills

This project uses the **bombest** skill set for build automation. All skills are prefixed with `bombest-` for easy discovery. These are the primary interface — prefer them over running scripts directly.

| Skill              | What it does                                              |
|--------------------|-----------------------------------------------------------|
| `/bombest-build`   | Build plugin binaries for specified formats and tier      |
| `/bombest-sign`    | Code sign and notarize binaries                           |
| `/bombest-deploy`  | Deploy to S3 with auto-generated release notes            |
| `/bombest-version` | Bump versions, tag releases, check deployment status      |
| `/bombest-release` | Full pipeline: version → build → sign → deploy            |

### Quick examples

```
"build it"                  → /bombest-build (dev, all formats)
"make an alpha"             → /bombest-build (alpha, all formats) → /bombest-sign
"what version are we on"    → /bombest-version status
"ship it"                   → /bombest-release (full pipeline)
"deploy this alpha"         → /bombest-deploy (alpha tier)
"just build the VST and AU" → /bombest-build (dev, VST3+AU)
```

## Scripts

All build scripts live in `scripts/` and are prefixed with `bombest-`. They read config from `build.json` and are designed to be deterministic and repeatable.

| Script                              | Purpose                                |
|-------------------------------------|----------------------------------------|
| `scripts/bombest-build.sh`          | CMake configure + build                |
| `scripts/bombest-sign.sh`           | Code signing (ad hoc or full)          |
| `scripts/bombest-notarize.sh`       | Apple notarization + stapling          |
| `scripts/bombest-deploy.sh`         | S3 upload + manifest generation        |
| `scripts/bombest-version.sh`        | Version bumping + git tagging          |
| `scripts/bombest-generate-index.sh` | Rebuild the S3 static site index       |

Direct script CLI usage:
```bash
# Build
./scripts/bombest-build.sh [--formats VST3,AU] [--config Release|Debug] [--clean]

# Sign
./scripts/bombest-sign.sh --tier <dev|alpha|release> [--formats FILTER]

# Deploy
./scripts/bombest-deploy.sh --tier <tier> --version X.Y.Z [--notes <file>] [--dry-run]

# Version
./scripts/bombest-version.sh [--status | --bump major|minor|patch | --set X.Y.Z] [--tag]
```

## Safety Rules

- **Never modify signing commands or codesign invocations** without explicit user confirmation
- **Never change version numbers** unless the user explicitly asks
- Check `build.json` before any build/deploy task — it is the single configuration source of truth

## Plugin Code Conventions

When working on plugin source code in the consuming project:

- C++17 standard
- JUCE coding conventions: PascalCase classes, camelCase methods
- Audio processing in `src/`, following JUCE's AudioProcessor/AudioProcessorEditor pattern

## Dependencies

- CMake, Ninja: `brew install cmake ninja`
- jq (for scripts): `brew install jq`
- AWS CLI (for deployment): `brew install awscli`
- Xcode CLI tools: `xcode-select --install`
- A valid Apple Developer account (for release signing/notarization)
