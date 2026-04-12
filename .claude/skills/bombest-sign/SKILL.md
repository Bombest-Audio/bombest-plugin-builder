---
name: bombest-sign
description: Code sign and optionally notarize plugin binaries. Handles ad hoc signing for alpha builds and full Developer ID signing plus Apple notarization for release builds. Use when the user mentions signing, notarizing, codesigning, preparing plugins for distribution, or "getting it ready for testers". Also triggers after a successful build when the tier is alpha or release, or when the user says things like "sign it", "notarize", or "prep for distribution".
argument-hint: "[tier]"
---

# /bombest-sign

Code sign (and optionally notarize) plugin binaries.

## Signing tiers

| Tier    | What happens                                       |
|---------|----------------------------------------------------|
| dev     | Nothing — dev builds are unsigned                  |
| alpha   | Ad hoc codesign for tester distribution             |
| release | Full Developer ID signing + Apple notarization      |

## Steps

### 1. Pre-flight

Read `build.json` for signing identities and notarization profile. Then verify the signing environment:

```bash
# Check that the signing identity exists
security find-identity -v -p codesigning
```

If the required identity isn't found:
- **For alpha**: ad hoc signing (`-`) always works, no identity needed
- **For release**: the Developer ID certificate must be in the keychain. Guide the user:
  - Check if it's expired: `security find-identity -v -p codesigning | grep "Developer ID"`
  - If missing entirely, they need to download from Apple Developer portal → Certificates
  - If expired, they need to renew through Xcode → Settings → Accounts

### 2. Sign

Run the signing script:

```bash
./scripts/bombest-sign.sh --tier <tier>
```

Optionally filter formats: `--formats VST3,AU`

### 3. Notarize (release only)

For release tier, after signing succeeds, run notarization:

```bash
./scripts/bombest-notarize.sh --all
```

Notarization typically takes 2-15 minutes. Let the user know this is normal. The script waits automatically and reports progress.

If notarization is rejected, the script fetches the Apple log. Common issues:
- **Unsigned or improperly signed binaries**: re-sign with the full identity
- **Hardened runtime issues**: ensure `--options runtime` was used (the script does this)
- **Embedded unsigned libraries**: find them with `codesign --deep --verify` and sign individually
- **Notarization profile not set up**: guide the user through:
  ```bash
  xcrun notarytool store-credentials "notarize-profile" \
    --apple-id <apple-id-from-build.json> \
    --team-id <team-id-from-build.json> \
    --password <app-specific-password>
  ```
  They'll need to generate an app-specific password at appleid.apple.com

### 4. Verify

```bash
./scripts/bombest-sign.sh --tier <tier> --verify-only
```

Report the verification status for each binary.

### 5. Next step

After successful signing (and notarization for release), suggest: "Signed and verified. Ready to deploy? (`/bombest-deploy`)"

## Important

- Never attempt to sign without first confirming the identity exists
- For AAX plugins: AAX has its own signing process through Avid's PACE tools — this script handles codesign only. Remind the user if they're building AAX for distribution that they may also need PACE wrapping.
- Keep the signing identity strings exactly as they appear in build.json — even small differences will cause failures
