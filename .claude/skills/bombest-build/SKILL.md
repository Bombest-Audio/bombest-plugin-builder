---
name: bombest-build
description: Build audio plugin binaries for one or more formats (VST3, CLAP, AU, AAX, Standalone) at a specified tier (dev, alpha, release). Use this skill whenever the user mentions building, compiling, or making a build of their plugin — even casually like "build it" or "make a dev build". Also triggers on format names like "build the VST" or tier names like "make an alpha". Even partial matches like "compile", "cmake", or "just the AU" should trigger this.
argument-hint: "[tier] [formats]"
---

# /bombest-build

Build plugin binaries using CMake + JUCE.

## Interpreting the request

Parse the user's intent into two parameters:

- **tier**: dev (default), alpha, or release
- **formats**: which formats to build — default is all five (VST3, CLAP, AU, AAX, Standalone)

The user might say things like:
- "build it" → dev, all formats
- "make an alpha" → alpha, all formats
- "build VST3 and AU for testing" → dev, VST3+AU
- "release build" → release, all formats
- "just the clap" → dev, CLAP only

Use `Debug` config for dev tier, `Release` for alpha and release.

## Steps

1. Read `build.json` in the project root to confirm plugin name, formats, and build config
2. Run the build script with the appropriate flags:
   ```bash
   ./scripts/bombest-build.sh --formats <comma-separated> --config <Release|Debug>
   ```
   Add `--clean` if the user mentions wanting a clean build, or if a previous build failed with weird errors.
3. If the build succeeds, report:
   - Which binaries were produced and their sizes
   - Total build time
   - Which tier/config was used
4. If the build fails, read the error output carefully and diagnose:
   - **Missing JUCE modules** → suggest `git submodule update --init --recursive`
   - **CMake config errors** → check CMakeLists.txt, suggest specific fixes
   - **Compiler errors** → show the relevant source lines and suggest a fix
   - **Ninja/Make not found** → suggest `brew install ninja` or `brew install cmake`
   - **Xcode CLI tools missing** → suggest `xcode-select --install`
5. For alpha and release tiers, after a successful build, ask: "Build complete. Want me to sign these? (`/bombest-sign`)"

## Important

- Never modify CMakeLists.txt or source code during a build unless the user explicitly asks
- Always show build warnings — they often catch real issues in audio plugin code
- If the user asks to build a format that isn't in build.json's plugin_formats list, warn them but attempt it anyway
