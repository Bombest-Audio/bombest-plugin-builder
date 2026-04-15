#!/bin/bash

#
# Bombest Plugin Builder - Deployment Script
# Deploys plugin builds to S3 with manifest generation and index updates
#

set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Configuration defaults
TIER=""
VERSION=""
NOTES_FILE=""
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_CONFIG="${PROJECT_ROOT}/build.json"

# Validate build.json exists
if [[ ! -f "$BUILD_CONFIG" ]]; then
    log_error "build.json not found at $BUILD_CONFIG"
    exit 1
fi

# Read configuration from build.json
PLUGIN_NAME=$(jq -r '.plugin_name' "$BUILD_CONFIG")
BUILD_DIR=$(jq -r '.build_dir' "$BUILD_CONFIG")
S3_BUCKET=$(jq -r '.s3_bucket' "$BUILD_CONFIG")
S3_REGION=$(jq -r '.s3_region' "$BUILD_CONFIG")
SITE_URL=$(jq -r '.site_url' "$BUILD_CONFIG")
S3_PLUGIN_PREFIX=$(jq -r 'if .s3_plugin_prefix == false then "false" else "true" end' "$BUILD_CONFIG")

# Validate required config values
if [[ -z "$PLUGIN_NAME" || "$PLUGIN_NAME" == "null" ]]; then
    log_error "plugin_name not configured in build.json"
    exit 1
fi
if [[ -z "$BUILD_DIR" || "$BUILD_DIR" == "null" ]]; then
    log_error "build_dir not configured in build.json"
    exit 1
fi
if [[ -z "$S3_BUCKET" || "$S3_BUCKET" == "null" ]]; then
    log_error "s3_bucket not configured in build.json"
    exit 1
fi
if [[ -z "$S3_REGION" || "$S3_REGION" == "null" ]]; then
    log_error "s3_region not configured in build.json"
    exit 1
fi

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tier)
            TIER="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --notes)
            NOTES_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$TIER" ]]; then
    log_error "Missing required argument: --tier [dev|alpha|release]"
    exit 1
fi

if [[ "$TIER" != "dev" && "$TIER" != "alpha" && "$TIER" != "release" ]]; then
    log_error "Invalid tier: $TIER (must be dev, alpha, or release)"
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    log_error "Missing required argument: --version X.Y.Z"
    exit 1
fi

# Validate version format (X.Y.Z)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "Invalid version format: $VERSION (expected X.Y.Z)"
    exit 1
fi

# Validate notes file if provided
if [[ -n "$NOTES_FILE" ]] && [[ ! -f "$NOTES_FILE" ]]; then
    log_error "Notes file not found: $NOTES_FILE"
    exit 1
fi

# Validate build directory
if [[ ! -d "$BUILD_DIR" ]]; then
    log_error "Build directory not found: $BUILD_DIR"
    exit 1
fi

# Get git information
GIT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
ISO_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log_info "Deploying ${PLUGIN_NAME} v${VERSION} to tier: ${TIER}"
log_info "Git SHA: $GIT_SHA, Branch: $GIT_BRANCH"

# Create staging directory
STAGING_DIR=$(mktemp -d -t bombest-deploy.XXXXXXXX)
trap "rm -rf '$STAGING_DIR'" EXIT
log_info "Staging directory: $STAGING_DIR"

# Copy plugin bundles from build_dir to staging (only actual plugin formats, not CMake artifacts)
log_info "Copying plugin bundles from ${BUILD_DIR}..."
staged_count=0
while IFS= read -r -d '' bundle; do
    cp -r "$bundle" "$STAGING_DIR/"
    log_info "  Staged: $(basename "$bundle")"
    staged_count=$((staged_count + 1))
done < <(find "$BUILD_DIR" -type d \( \
    -name "*.vst3" -o -name "*.clap" -o \
    -name "*.component" -o -name "*.aaxplugin" -o \
    -name "*.app" \) -print0 2>/dev/null)

# Check if anything was staged
if [[ "$staged_count" -eq 0 ]]; then
    log_error "No plugin bundles found in ${BUILD_DIR}. Run bombest-build.sh first."
    exit 1
fi
log_info "Staged ${staged_count} plugin bundle(s)"

# Copy release notes if provided
if [[ -n "$NOTES_FILE" ]]; then
    cp "$NOTES_FILE" "$STAGING_DIR/RELEASE_NOTES.md"
    log_info "Included release notes"
fi

# Gather file information for manifest (bash 3.2 compatible — no associative arrays)
declare -a FILE_LIST
COUNT_VST3=0; COUNT_CLAP=0; COUNT_AU=0; COUNT_AAX=0

while IFS= read -r -d '' file; do
    filename=$(basename "$file")
    if [[ "$file" == *.vst3* ]]; then
        COUNT_VST3=$((COUNT_VST3 + 1)); FILE_LIST+=("${filename}|vst3")
    elif [[ "$file" == *.clap* ]]; then
        COUNT_CLAP=$((COUNT_CLAP + 1)); FILE_LIST+=("${filename}|clap")
    elif [[ "$file" == *.component* ]]; then
        COUNT_AU=$((COUNT_AU + 1)); FILE_LIST+=("${filename}|au")
    elif [[ "$file" == *.aaxplugin* ]]; then
        COUNT_AAX=$((COUNT_AAX + 1)); FILE_LIST+=("${filename}|aax")
    fi
done < <(find "$STAGING_DIR" -type f -print0)

# Build formats array for manifest
FORMATS_JSON="["
first=true
for pair in "vst3:$COUNT_VST3" "clap:$COUNT_CLAP" "au:$COUNT_AU" "aax:$COUNT_AAX"; do
    fmt="${pair%%:*}"; cnt="${pair##*:}"
    [[ "$cnt" -eq 0 ]] && continue
    [[ "$first" == false ]] && FORMATS_JSON+=","
    FORMATS_JSON+="{\"format\":\"$fmt\",\"count\":$cnt}"
    first=false
done
FORMATS_JSON+="]"

# Calculate total size
TOTAL_SIZE=$(find "$STAGING_DIR" -type f -exec stat -f%z {} \; | awk '{sum+=$1} END{print sum+0}')

# Generate manifest.json
MANIFEST_FILE="$STAGING_DIR/manifest.json"
cat > "$MANIFEST_FILE" <<EOF
{
  "plugin_name": "$PLUGIN_NAME",
  "version": "$VERSION",
  "tier": "$TIER",
  "date": "$ISO_DATE",
  "git_sha": "$GIT_SHA",
  "git_branch": "$GIT_BRANCH",
  "formats": $FORMATS_JSON,
  "total_size_bytes": $TOTAL_SIZE
}
EOF

log_success "Generated manifest.json"
log_info "Manifest contents:"
cat "$MANIFEST_FILE" | jq '.' | sed 's/^/  /'

# Generate release index.html — served when browser navigates to the version directory
RELEASE_NOTES_HTML=""
if [[ -n "$NOTES_FILE" ]]; then
    # Convert markdown-ish notes to simple HTML paragraphs
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            RELEASE_NOTES_HTML+="<br>"
        elif [[ "$line" == "##"* ]]; then
            heading="${line###* }"
            RELEASE_NOTES_HTML+="<h3>${heading}</h3>"
        elif [[ "$line" == "-"* || "$line" == "*"* ]]; then
            item="${line#[-*] }"
            RELEASE_NOTES_HTML+="<li>${item}</li>"
        else
            RELEASE_NOTES_HTML+="<p>${line}</p>"
        fi
    done < "$NOTES_FILE"
    RELEASE_NOTES_HTML="<section class=\"notes\"><h2>Release Notes</h2><ul>${RELEASE_NOTES_HTML}</ul></section>"
fi

FORMATS_HTML=""
for pair in "vst3:$COUNT_VST3:VST3" "clap:$COUNT_CLAP:CLAP" "au:$COUNT_AU:AU" "aax:$COUNT_AAX:AAX"; do
    ext="${pair%%:*}"; rest="${pair#*:}"; cnt="${rest%%:*}"; label="${rest##*:}"
    [[ "$cnt" -eq 0 ]] && continue
    # Find the matching bundle name
    bundle_name=""
    for entry in ${FILE_LIST[@]+"${FILE_LIST[@]}"}; do
        if [[ "${entry##*|}" == "$ext" ]]; then
            bundle_name="${entry%%|*}"
            break
        fi
    done
    FORMATS_HTML+="<div class=\"format\"><span class=\"badge\">${label}</span><span class=\"fname\">${bundle_name}</span></div>"
done

DISPLAY_DATE=$(echo "$ISO_DATE" | sed 's/T/ /' | sed 's/Z/ UTC/')
TIER_UPPER=$(echo "$TIER" | tr '[:lower:]' '[:upper:]')

cat > "$STAGING_DIR/index.html" <<PAGEEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${PLUGIN_NAME} v${VERSION} (${TIER})</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f0f0f; color: #e8e8e8; min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 2rem 1rem; }
    .card { background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 12px; padding: 2.5rem; max-width: 640px; width: 100%; }
    .header { margin-bottom: 2rem; }
    h1 { font-size: 1.8rem; font-weight: 700; color: #fff; margin-bottom: 0.4rem; }
    .meta { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; }
    .badge { display: inline-block; padding: 0.2rem 0.6rem; border-radius: 4px; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; }
    .badge-alpha { background: #7c3f00; color: #ffb347; }
    .badge-release { background: #1a3d1a; color: #6fcf6f; }
    .badge-dev { background: #1a1a3d; color: #6f9fcf; }
    .badge-format { background: #2a2a2a; color: #aaa; }
    .date { font-size: 0.85rem; color: #666; }
    .sha { font-size: 0.8rem; color: #555; font-family: monospace; }
    .formats { margin: 1.5rem 0; display: flex; flex-direction: column; gap: 0.6rem; }
    .format { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 1rem; background: #222; border-radius: 6px; border: 1px solid #2a2a2a; }
    .fname { font-family: monospace; font-size: 0.85rem; color: #bbb; }
    .notes { margin-top: 1.5rem; padding-top: 1.5rem; border-top: 1px solid #2a2a2a; }
    .notes h2 { font-size: 1rem; color: #999; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 1rem; }
    .notes h3 { font-size: 0.95rem; color: #ccc; margin: 0.75rem 0 0.4rem; }
    .notes p, .notes li { font-size: 0.9rem; color: #aaa; line-height: 1.6; }
    .notes ul { padding-left: 1.2rem; }
    .notes li { margin-bottom: 0.3rem; }
    .footer { margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #2a2a2a; font-size: 0.8rem; color: #555; display: flex; justify-content: space-between; }
    a { color: #6f9fcf; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <h1>${PLUGIN_NAME} <span style="color:#666">v${VERSION}</span></h1>
      <div class="meta">
        <span class="badge badge-${TIER}">${TIER_UPPER}</span>
        <span class="date">${DISPLAY_DATE}</span>
        <span class="sha">${GIT_SHA}</span>
      </div>
    </div>

    <div class="formats">
${FORMATS_HTML}
    </div>

    ${RELEASE_NOTES_HTML}

    <div class="footer">
      <span><a href="manifest.json">manifest.json</a></span>
      <span><a href="RELEASE_NOTES.md">RELEASE_NOTES.md</a></span>
    </div>
  </div>
</body>
</html>
PAGEEOF

log_success "Generated index.html"

# Build S3 path — optionally prefix with plugin name (set s3_plugin_prefix=false to omit)
if [[ "$S3_PLUGIN_PREFIX" == "true" ]]; then
    S3_PATH="${PLUGIN_NAME}/${TIER}/${VERSION}/"
else
    S3_PATH="${TIER}/${VERSION}/"
fi

if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN MODE: Showing what would be uploaded (not actually syncing)"
    log_info "S3 destination: s3://${S3_BUCKET}/${S3_PATH}"
    log_info "Files to upload:"
    find "$STAGING_DIR" -type f | sed "s|^$STAGING_DIR/|  |"
    log_warn "DRY RUN: Skipping S3 sync"
else
    # Upload to S3
    S3_DEST="s3://${S3_BUCKET}/${S3_PATH}"
    log_info "Syncing to S3: $S3_DEST"

    if aws s3 sync "$STAGING_DIR" "$S3_DEST" \
        --region "$S3_REGION" \
        --delete \
        --no-progress >/dev/null 2>&1; then
        log_success "Files uploaded successfully"
    else
        log_error "Failed to sync files to S3"
        exit 1
    fi

    # Update latest.txt pointer
    LATEST_POINTER_FILE=$(mktemp)
    echo "$VERSION" > "$LATEST_POINTER_FILE"

    if aws s3 cp "$LATEST_POINTER_FILE" "s3://${S3_BUCKET}/${TIER}/latest.txt" \
        --region "$S3_REGION" \
        --content-type "text/plain" >/dev/null 2>&1; then
        log_success "Updated latest.txt pointer"
    else
        log_error "Failed to update latest.txt"
        rm -f "$LATEST_POINTER_FILE"
        exit 1
    fi
    rm -f "$LATEST_POINTER_FILE"

    # Verify upload
    log_info "Verifying S3 upload..."
    if aws s3 ls "$S3_DEST" --region "$S3_REGION" >/dev/null 2>&1; then
        log_success "Upload verified"
    else
        log_error "Upload verification failed"
        exit 1
    fi
fi

# Generate site index
log_info "Regenerating site index..."
if [[ -f "$SCRIPT_DIR/bombest-generate-index.sh" ]]; then
    if "$SCRIPT_DIR/bombest-generate-index.sh"; then
        log_success "Site index regenerated"
    else
        if [[ "$DRY_RUN" == true ]]; then
            log_warn "Index generation failed in dry-run (expected if S3 is not accessible)"
        else
            log_error "Failed to regenerate site index"
            exit 1
        fi
    fi
else
    log_warn "bombest-generate-index.sh not found, skipping index generation"
fi

# Final report
BUILD_URL="${SITE_URL}/${TIER}/${VERSION}/"
if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN COMPLETE - No changes were made to S3"
else
    log_success "Deployment complete!"
    log_info "Plugin available at: ${BUILD_URL}"
    log_info "Direct S3 URL: s3://${S3_BUCKET}/${S3_PATH}"
fi

exit 0
