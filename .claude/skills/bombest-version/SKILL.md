---
name: bombest-version
description: Manage plugin versioning — bump major/minor/patch, tag releases, check what version is current, and see what's deployed to each tier. Use when the user mentions version bumps, tagging, releasing, or asks "what version are we on", "what's deployed", "bump the version", or "tag it". Also triggers on "what's live" or "status".
argument-hint: "[bump type or 'status']"
---

# /bombest-version

Manage plugin version numbers, git tags, and deployment status.

## Commands

### Status (default if no bump specified)

Show the full picture:

1. **Current version** from CMakeLists.txt:
   ```bash
   grep -oP 'PROJECT_VERSION\s+\K[0-9]+\.[0-9]+\.[0-9]+' CMakeLists.txt
   ```

2. **Git state**:
   ```bash
   git describe --tags --long 2>/dev/null
   git status --short
   ```

3. **Deployed versions** per tier:
   ```bash
   # Read build.json for bucket/plugin info
   for tier in dev alpha release; do
     aws s3 cp "s3://<bucket>/<plugin>/${tier}/latest.txt" - 2>/dev/null || echo "nothing deployed"
   done
   ```

4. **Recent tags**:
   ```bash
   git tag --sort=-version:refname | head -5
   ```

Present this as a clear, scannable summary. Something like:

```
Plugin: YourPlugin
Version: 1.3.2 (CMakeLists.txt)
Git: v1.3.1-4-g8a3b2c1 (4 commits since last tag, dirty)

Deployed:
  release: 1.3.0  ← 2 versions behind
  alpha:   1.3.1
  dev:     1.3.2

Recent tags: v1.3.1, v1.3.0, v1.2.5, v1.2.4, v1.2.3
```

### Version bump

1. Confirm the bump type if ambiguous:
   - "bump it" → ask major/minor/patch (suggest patch as default)
   - "minor bump" → minor, no need to ask
   - "bump to 2.0" → use `--set 2.0.0`

2. Run the version script:
   ```bash
   ./scripts/bombest-version.sh --bump <type> --tag
   ```

   Or for explicit version:
   ```bash
   ./scripts/bombest-version.sh --set <X.Y.Z> --tag
   ```

3. Show what changed:
   ```bash
   git diff HEAD~1
   ```

4. Suggest next step: "Version bumped to X.Y.Z and tagged. Ready to build? (`/bombest-build`)"

## Important

- Version bumps with `--tag` create a git commit and annotated tag automatically
- For release versions, the user should be on the main/master branch
- If there are uncommitted changes, warn before bumping — they should commit or stash first
- The version script updates both CMakeLists.txt and src/PluginInfo.h (if it exists)
