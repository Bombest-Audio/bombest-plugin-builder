# Bombest Plugin Builder Scripts

Two production-quality shell scripts for building and versioning JUCE audio plugins with CMake.

## Scripts

### 1. `scripts/build.sh` - Build Script

Compiles audio plugins for multiple formats (VST3, CLAP, AU, AAX).

**Features:**
- Reads configuration from `build.json` using `jq`
- Supports multiple plugin formats with selective building
- Parallel compilation (`-j$(nproc)`)
- Clean builds with `--clean` flag
- Color-coded output (info, success, warnings, errors)
- Scans and reports all produced binaries with sizes
- Tracks total build time

**Usage:**
```bash
./scripts/build.sh                              # Build all formats, Release
./scripts/build.sh --formats VST3,CLAP          # Build specific formats
./scripts/build.sh --config Debug --clean       # Clean Debug build
```

**Arguments:**
- `--formats FORMAT1,FORMAT2,...` - Comma-separated plugin formats (default: all from build.json)
- `--config Release|Debug` - Build configuration (default: Release)
- `--clean` - Remove build directory before building (optional)

**Configuration (build.json):**
```json
{
  "plugin_name": "MyPlugin",
  "build_dir": "build",
  "cmake_generator": "Unix Makefiles",
  "cmake_extra_args": "-DCMAKE_OSX_DEPLOYMENT_TARGET=10.13",
  "plugin_formats": "VST3,CLAP,AU"
}
```

### 2. `scripts/version.sh` - Version Management Script

Manages semantic versioning for audio plugins with git integration.

**Features:**
- Read version status from CMakeLists.txt and git
- Bump semantic versions (major/minor/patch)
- Set explicit versions
- Auto-update `src/PluginInfo.h` if present
- Create annotated git tags
- Validate semver format (X.Y.Z)
- Color-coded output

**Usage:**
```bash
./scripts/version.sh --status                   # Show current version info
./scripts/version.sh --bump patch               # Bump patch version
./scripts/version.sh --set 2.1.0                # Set explicit version
./scripts/version.sh --bump minor --tag         # Bump and create git tag
```

**Arguments:**
- `--status` - Display current version info (default if no command)
- `--bump major|minor|patch` - Increment semantic version
- `--set X.Y.Z` - Set explicit version
- `--tag` - Create git commit and annotated tag (can combine with --bump/--set)

**Updates:**
- `CMakeLists.txt`: `PROJECT_VERSION` or `project(...VERSION...)` statements
- `src/PluginInfo.h`: `PLUGIN_VERSION_STRING` define (if file exists)
- Git: Creates commit "Bump version to X.Y.Z" and tag `vX.Y.Z`

## Requirements

- `bash` 4.0+
- `jq` (for JSON parsing)
- `cmake` (for build.sh)
- `git` (for version.sh --tag)

## Installation

Both scripts are executable by default:
```bash
chmod +x scripts/build.sh scripts/version.sh
```

## Implementation Details

### build.sh
- **Error handling**: `set -euo pipefail` with detailed error messages
- **Color output**: BLUE=info, GREEN=success, RED=error, YELLOW=warnings
- **Cross-platform**: Works on macOS (sysctl) and Linux (nproc) for CPU count
- **Binary discovery**: Finds .vst3, .clap, .component, .aaxplugin, and standalone executables
- **Build time tracking**: Reports duration in minutes:seconds format

### version.sh
- **Git integration**: Detects git state, shows latest tag, git describe output
- **Atomic updates**: Updates both CMakeLists.txt and PluginInfo.h in sync
- **sed compatibility**: Handles macOS (`sed -i ''`) and Linux (`sed -i`) variations
- **Validation**: Enforces X.Y.Z semver format
- **Safe tagging**: Checks for existing tags before creation

## Common Workflows

### Clean Release Build
```bash
./scripts/build.sh --config Release --clean
```

### Bump Patch Version and Tag
```bash
./scripts/version.sh --bump patch --tag
./scripts/build.sh --config Release
```

### Development Workflow
```bash
./scripts/version.sh --status              # Check current version
./scripts/build.sh --formats VST3 --config Debug  # Quick test build
```

### Release Workflow
```bash
./scripts/version.sh --bump minor --tag    # Bump and tag
./scripts/build.sh --clean                 # Clean Release build
# Deploy binaries from build/ directory
```

## Troubleshooting

**jq not found:**
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq

# Fedora
sudo dnf install jq
```

**CMake generator not found:**
Check `build.json` cmake_generator matches your system:
- macOS: "Unix Makefiles" or "Xcode"
- Linux: "Unix Makefiles" or "Ninja"
- Windows: "Visual Studio 16 2019"

**Build fails with "target not found":**
Verify plugin format names in --formats match JUCE target names (usually uppercase: VST3, CLAP, AU, AAX)

**git tag already exists:**
Use `git tag -d vX.Y.Z` to delete local tag, then retry version.sh --tag
