---
name: bombest-deploy
description: Deploy built and signed plugin binaries to the S3 static builds site with auto-generated release notes. Use when the user mentions deploying, publishing, uploading, shipping, pushing a build, or updating the builds site. Also triggers when they say "send this to testers", "put this up", "push the build", or "update the site". Handles release note generation from git history, S3 upload, and index page regeneration.
argument-hint: "[tier] [version]"
---

# /bombest-deploy

Deploy plugin binaries to the S3 builds site with release notes.

## Steps

### 1. Gather context

Read `build.json` for S3 bucket, region, and site URL. Then determine:

- **Version**: read from CMakeLists.txt (`PROJECT_VERSION`)
- **Tier**: infer from context or ask. Clues: if they just did a release build, it's release. "Send to testers" = alpha. Default = dev.
- **Git state**: make sure working directory is clean for alpha/release. Dev can be dirty.

### 2. Generate release notes

This is where the AI adds the most value over the old Bombest app. Generate human-readable release notes from the git history:

```bash
# Find the last deployed tag for this tier
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

# Get commits since last tag (or all commits if no tag)
if [ -n "$LAST_TAG" ]; then
  git log --oneline "$LAST_TAG"..HEAD
else
  git log --oneline -20
fi
```

From the commits, write release notes categorized into:
- **New**: genuinely new features or capabilities
- **Improved**: enhancements to existing functionality
- **Fixed**: bug fixes
- **Internal**: refactoring, build system changes (include for dev/alpha, omit for release)

Write for the audience:
- **dev notes**: can be technical, reference code
- **alpha notes**: aimed at testers, mention what to test
- **release notes**: aimed at end users, no jargon

Save to a temp file and **show the draft to the user for approval** before deploying. This is a hard requirement — never deploy without the user seeing the release notes first.

### 3. Verify binaries

Before uploading, confirm the binaries are ready:

```bash
# Check binaries exist
ls build/**/*.{vst3,clap,component,aaxplugin} 2>/dev/null

# For alpha/release: verify signing
./scripts/bombest-sign.sh --tier <tier> --verify-only
```

If binaries aren't signed for a tier that requires it, stop and suggest running `/bombest-sign` first.

### 4. Deploy

After the user approves the release notes:

```bash
./scripts/bombest-deploy.sh --tier <tier> --version <version> --notes /tmp/bombest-release-notes.md
```

Use `--dry-run` first if the user seems uncertain, then do the real deploy.

### 5. Report

After deployment:
- Show the direct URL: `<site_url>/<plugin_name>/<tier>/<version>/`
- Confirm the index page was regenerated
- For alpha: "Testers can grab the build at: <url>"
- For release: "Release is live at: <url>"

## Important

- Always show release notes before deploying — the user must approve
- Verify AWS credentials are configured before attempting deploy (`aws sts get-caller-identity`)
- If the S3 bucket doesn't exist or permissions fail, help troubleshoot IAM/bucket policy
- The deploy script updates `latest.txt` and rebuilds the index automatically
