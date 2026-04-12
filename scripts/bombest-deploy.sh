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

# Copy plugin binaries from build_dir to staging
log_info "Copying plugin binaries from ${BUILD_DIR}..."
if ! cp -r "$BUILD_DIR"/* "$STAGING_DIR/" 2>/dev/null; then
    log_warn "No files found in build directory or copy had warnings"
fi

# Check if anything was staged
if [[ -z "$(find "$STAGING_DIR" -type f)" ]]; then
    log_error "No files were staged. Check that build_dir contains plugin binaries."
    exit 1
fi

# Copy release notes if provided
if [[ -n "$NOTES_FILE" ]]; then
    cp "$NOTES_FILE" "$STAGING_DIR/RELEASE_NOTES.md"
    log_info "Included release notes"
fi

# Gather file information for manifest
declare -A FORMAT_COUNTS
declare -a FILE_LIST

while IFS= read -r -d '' file; do
    # Determine format from extension
    filename=$(basename "$file")

    if [[ "$file" == *.vst3* ]]; then
        FORMAT_COUNTS["vst3"]=$((${FORMAT_COUNTS["vst3"]:-0} + 1))
        FILE_LIST+=("${filename}|vst3")
    elif [[ "$file" == *.clap* ]]; then
        FORMAT_COUNTS["clap"]=$((${FORMAT_COUNTS["clap"]:-0} + 1))
        FILE_LIST+=("${filename}|clap")
    elif [[ "$file" == *.component* ]]; then
        FORMAT_COUNTS["au"]=$((${FORMAT_COUNTS["au"]:-0} + 1))
        FILE_LIST+=("${filename}|au")
    elif [[ "$file" == *.aaxplugin* ]]; then
        FORMAT_COUNTS["aax"]=$((${FORMAT_COUNTS["aax"]:-0} + 1))
        FILE_LIST+=("${filename}|aax")
    fi
done < <(find "$STAGING_DIR" -type f -print0)

# Build formats array for manifest
FORMATS_JSON="["
first=true
for format in "${!FORMAT_COUNTS[@]}"; do
    if [[ "$first" == false ]]; then
        FORMATS_JSON+=","
    fi
    FORMATS_JSON+="{\"format\":\"$format\",\"count\":${FORMAT_COUNTS[$format]}}"
    first=false
done
FORMATS_JSON+="]"

# Calculate total size
TOTAL_SIZE=$(du -sb "$STAGING_DIR" | awk '{print $1}')

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

if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN MODE: Showing what would be uploaded (not actually syncing)"
    log_info "S3 destination: s3://${S3_BUCKET}/${PLUGIN_NAME}/${TIER}/${VERSION}/"
    log_info "Files to upload:"
    find "$STAGING_DIR" -type f | sed "s|^$STAGING_DIR/|  |"
    log_warn "DRY RUN: Skipping S3 sync"
else
    # Upload to S3
    S3_DEST="s3://${S3_BUCKET}/${PLUGIN_NAME}/${TIER}/${VERSION}/"
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

    if aws s3 cp "$LATEST_POINTER_FILE" "s3://${S3_BUCKET}/${PLUGIN_NAME}/${TIER}/latest.txt" \
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
BUILD_URL="${SITE_URL}/builds/"
if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN COMPLETE - No changes were made to S3"
else
    log_success "Deployment complete!"
    log_info "Plugin available at: ${BUILD_URL}"
    log_info "Direct S3 URL: s3://${S3_BUCKET}/${PLUGIN_NAME}/${TIER}/${VERSION}/"
fi

exit 0
