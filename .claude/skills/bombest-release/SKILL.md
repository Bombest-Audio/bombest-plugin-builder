---
name: bombest-release
description: Run the full release pipeline — version bump, build all formats, code sign, notarize, and deploy to S3 with release notes. This is the "do everything" command. Use when the user says "cut a release", "ship it", "do a full release", "release 1.3.0", "push an alpha", or anything that implies the complete build-to-deploy pipeline. Even "let's get this out" or "time to ship" should trigger this. For single steps (just build, just sign), use the individual bombest skills instead.
argument-hint: "[tier] [version bump type]"
---

# /bombest-release

Run the full build → sign → deploy pipeline in sequence.

## Determine scope

Parse the user's intent:

- **Tier**: release (default for "ship it"), alpha ("push an alpha"), dev ("deploy dev")
- **Version bump**: patch (default), minor, major, or none (if they specify an exact version or say "don't bump")

If ambiguous, ask. For example, "ship it" with no other context → confirm: "I'll cut a release with a patch bump. That'll take you from X.Y.Z to X.Y.(Z+1). Sound right?"

## Pipeline

Run each stage in order. Report progress at each step. Stop immediately on failure.

### 1. Pre-flight checks

```bash
# Clean working directory?
git status --short

# On the right branch?
git branch --show-current

# Signing identity available?
security find-identity -v -p codesigning

# AWS credentials?
aws sts get-caller-identity
```

**Branch expectations** (from build.json):
- release tier → should be on main/master
- alpha tier → develop or feature branch is fine
- dev tier → any branch

If pre-flight fails, explain what's wrong and how to fix it. Don't proceed.

### 2. Version bump

Skip if the user said "don't bump" or already bumped manually.

```bash
./scripts/bombest-version.sh --bump <type> --tag
```

Report: "Version bumped: X.Y.Z → A.B.C"

### 3. Build all formats

```bash
./scripts/bombest-build.sh --config Release
```

For dev tier, use `--config Debug` instead.

Report: "Built 5 formats in Xm Ys"

If build fails, stop the pipeline. Diagnose the error and suggest fixes.

### 4. Code sign

```bash
./scripts/bombest-sign.sh --tier <tier>
```

For release tier, also notarize:
```bash
./scripts/bombest-notarize.sh --all
```

Let the user know notarization takes a few minutes. Report progress as it comes.

Report: "Signed and verified all formats" or "Signed, notarized, and stapled all formats"

### 5. Generate release notes and deploy

Generate release notes from git history (see `/bombest-deploy` skill for the approach). **Show the notes to the user and wait for approval.**

After approval:
```bash
./scripts/bombest-deploy.sh --tier <tier> --version <version> --notes /tmp/bombest-release-notes.md
```

### 6. Post-release

For release and alpha tiers:
```bash
# Push the tag
git push origin v<version>

# Push the branch
git push
```

### 7. Summary

Print a final summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Bombest Release Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Plugin:   YourPlugin
  Version:  1.4.0
  Tier:     release
  Formats:  VST3, CLAP, AU, AAX, Standalone
  Tag:      v1.4.0
  URL:      https://builds.yourdomain.com/YourPlugin/release/1.4.0/
  Time:     4m 32s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Handling failures

If any step fails:
1. Stop the pipeline immediately
2. Explain what failed and why
3. Suggest the fix
4. Tell the user they can re-run `/bombest-release` after fixing — the scripts are idempotent, so re-running is safe

If the version was already bumped but build failed, don't bump again on retry — detect that the tag already exists.

## Important

- The release notes approval step is mandatory — never skip it
- For release tier, all five formats must build and sign successfully. Don't deploy partial builds.
- The pipeline should feel like a conversation, not a silent black box. Report progress at each stage.
- If the user says "skip notarization" or "just sign, don't notarize", respect that
