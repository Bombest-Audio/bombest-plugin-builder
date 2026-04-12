# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **Bombest Plugin Builder** — a build, signing, versioning, and deployment framework for JUCE audio plugins. It is **not a complete plugin project**. The consuming project provides its own `CMakeLists.txt`, `src/`, and `libs/JUCE`. This repo supplies the scripts and Claude skills that wrap them.

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
