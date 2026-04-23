#!/bin/bash

################################################################################
# Audio Plugin Version Manager
# Manages semantic versioning for JUCE audio plugins
#
# Usage:
#   ./version.sh --status                    # Show current version info
#   ./version.sh --bump major|minor|patch    # Bump semantic version
#   ./version.sh --set X.Y.Z                 # Set explicit version
#   ./version.sh --tag                       # Create git tag for current version
#
# Examples:
#   ./version.sh --status
#   ./version.sh --bump patch
#   ./version.sh --set 2.1.0 --tag
################################################################################

set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Validate semantic version format
validate_version() {
    local version=$1
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format: $version (expected X.Y.Z)"
        return 1
    fi
    return 0
}

# Parse semantic version
parse_version() {
    local version=$1
    local -n major=$2
    local -n minor=$3
    local -n patch=$4
    
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    patch=$(echo "$version" | cut -d. -f3)
}

# Bump semantic version
bump_version() {
    local version=$1
    local bump_type=$2
    
    parse_version "$version" major minor patch
    
    case $bump_type in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            log_error "Invalid bump type: $bump_type (must be major, minor, or patch)"
            return 1
            ;;
    esac
    
    echo "${major}.${minor}.${patch}"
}

# Find project root (directory containing build.json — the .bombest submodule dir)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Plugin repo root (parent of .bombest/) — this is where CMakeLists.txt lives
PLUGIN_PROJECT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
BUILD_CONFIG_FILE="$PROJECT_ROOT/build.json"

# Validate build.json exists
if [[ ! -f "$BUILD_CONFIG_FILE" ]]; then
    log_error "build.json not found at $BUILD_CONFIG_FILE"
    exit 1
fi

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

# Read plugin name from build.json
PLUGIN_NAME=$(jq -r '.plugin_name' "$BUILD_CONFIG_FILE")
log_info "Plugin name: $PLUGIN_NAME"

# CMakeLists.txt file location — in the consuming plugin repo, not the .bombest submodule
CMAKE_FILE="$PLUGIN_PROJECT_ROOT/CMakeLists.txt"
if [[ ! -f "$CMAKE_FILE" ]]; then
    log_error "CMakeLists.txt not found at $CMAKE_FILE"
    exit 1
fi

# Plugin info header (optional) — check both common layouts
if [[ -f "$PLUGIN_PROJECT_ROOT/Source/Version.h" ]]; then
    PLUGIN_INFO_FILE="$PLUGIN_PROJECT_ROOT/Source/Version.h"
else
    PLUGIN_INFO_FILE="$PLUGIN_PROJECT_ROOT/src/PluginInfo.h"
fi

# Parse command line arguments
COMMAND=""
BUMP_TYPE=""
NEW_VERSION=""
CREATE_TAG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --status)
            COMMAND="status"
            shift
            ;;
        --bump)
            COMMAND="bump"
            BUMP_TYPE="$2"
            if [[ ! "$BUMP_TYPE" =~ ^(major|minor|patch)$ ]]; then
                log_error "Invalid bump type: $BUMP_TYPE"
                exit 1
            fi
            shift 2
            ;;
        --set)
            COMMAND="set"
            NEW_VERSION="$2"
            validate_version "$NEW_VERSION" || exit 1
            shift 2
            ;;
        --tag)
            CREATE_TAG=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--status | --bump major|minor|patch | --set X.Y.Z] [--tag]"
            exit 1
            ;;
    esac
done

# Default to status if no command specified
if [[ -z "$COMMAND" ]]; then
    COMMAND="status"
fi

# Extract current version from CMakeLists.txt
# Look for PROJECT_VERSION or project(...VERSION...) statements
# Portable across BSD (macOS) and GNU sed — BSD grep has no -P.
# Matches either `PROJECT_VERSION X.Y.Z` or `project(... VERSION X.Y.Z ...)`.
CURRENT_VERSION=$(sed -nE 's/.*(PROJECT_VERSION|project\([^)]*VERSION)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\2/p' "$CMAKE_FILE" | head -n1)

if [[ -z "$CURRENT_VERSION" ]]; then
    log_warning "Could not determine current version from CMakeLists.txt"
    CURRENT_VERSION="0.0.0"
fi

log_info "Current version: $CURRENT_VERSION"

# Status command
if [[ "$COMMAND" == "status" ]]; then
    echo ""
    echo -e "${CYAN}=== Version Status ===${NC}"
    echo -e "Plugin:        ${CYAN}$PLUGIN_NAME${NC}"
    echo -e "CMakeLists.txt: ${CYAN}$CURRENT_VERSION${NC}"
    
    # Check git info if in a git repo
    if git rev-parse --git-dir > /dev/null 2>&1; then
        # Latest tag
        LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
        echo -e "Latest tag:    ${CYAN}$LATEST_TAG${NC}"
        
        # Git describe output
        GIT_DESCRIBE=$(git describe --always --tags 2>/dev/null || echo "unknown")
        echo -e "Git describe:  ${CYAN}$GIT_DESCRIBE${NC}"
        
        # Dirty/clean state
        if git diff-index --quiet HEAD -- 2>/dev/null; then
            echo -e "Git state:     ${GREEN}clean${NC}"
        else
            echo -e "Git state:     ${YELLOW}dirty${NC}"
        fi
    else
        echo -e "Git state:     ${YELLOW}not a git repository${NC}"
    fi
    
    if [[ -f "$PLUGIN_INFO_FILE" ]]; then
        PLUGIN_INFO_VERSION=$(sed -nE 's/.*PLUGIN_VERSION_STRING[[:space:]]+"v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$PLUGIN_INFO_FILE" 2>/dev/null | head -n1)
        if [[ -n "$PLUGIN_INFO_VERSION" ]]; then
            echo -e "PluginInfo.h:  ${CYAN}$PLUGIN_INFO_VERSION${NC}"
        fi
    fi
    
    echo ""
    exit 0
fi

# Bump or set command
if [[ "$COMMAND" == "bump" ]]; then
    NEW_VERSION=$(bump_version "$CURRENT_VERSION" "$BUMP_TYPE")
    log_info "Bumping $BUMP_TYPE: $CURRENT_VERSION → $NEW_VERSION"
elif [[ "$COMMAND" == "set" ]]; then
    log_info "Setting version: $CURRENT_VERSION → $NEW_VERSION"
fi

# Portable in-place sed: `-i.bak` works on both BSD (macOS) and GNU sed,
# and `-E` gives extended regex so `+`, `?`, `()` behave identically.
# BSD grep has no `\s`/`\+` — use `[[:space:]]` and explicit `+` under `-E`.

# Update CMakeLists.txt
log_info "Updating CMakeLists.txt..."
if ! grep -q "PROJECT_VERSION" "$CMAKE_FILE"; then
    log_warning "PROJECT_VERSION not found in CMakeLists.txt, looking for project() statement..."
    if grep -qE 'project\([^)]*VERSION' "$CMAKE_FILE"; then
        sed -i.bak -E "s/(project\([^)]*VERSION[[:space:]]+)[0-9]+\.[0-9]+\.[0-9]+/\1$NEW_VERSION/" "$CMAKE_FILE"
        rm -f "$CMAKE_FILE.bak"
    else
        log_error "Could not find PROJECT_VERSION or project(VERSION) in CMakeLists.txt"
        exit 1
    fi
else
    sed -i.bak -E "s/(PROJECT_VERSION[[:space:]]+)[0-9]+\.[0-9]+\.[0-9]+/\1$NEW_VERSION/" "$CMAKE_FILE"
    rm -f "$CMAKE_FILE.bak"
fi

log_success "CMakeLists.txt updated"

# Update PluginInfo.h if it exists
if [[ -f "$PLUGIN_INFO_FILE" ]]; then
    log_info "Updating PluginInfo.h..."
    if grep -q "PLUGIN_VERSION_STRING" "$PLUGIN_INFO_FILE"; then
        sed -i.bak -E "s/(PLUGIN_VERSION_STRING[[:space:]]+\")v?[0-9]+\.[0-9]+\.[0-9]+/\1$NEW_VERSION/" "$PLUGIN_INFO_FILE"
        rm -f "$PLUGIN_INFO_FILE.bak"
        log_success "PluginInfo.h updated"
    else
        log_warning "PLUGIN_VERSION_STRING not found in PluginInfo.h, skipping update"
    fi
fi

# Create git tag if requested
if [[ "$CREATE_TAG" == true ]]; then
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not a git repository, cannot create tag"
        exit 1
    fi
    
    log_info "Preparing git commit and tag..."
    
    # Check git state
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_info "Staging changed files..."
        git add "$CMAKE_FILE"
        
        if [[ -f "$PLUGIN_INFO_FILE" ]]; then
            git add "$PLUGIN_INFO_FILE"
        fi
        
        # Commit
        COMMIT_MSG="Bump version to $NEW_VERSION"
        log_info "Creating commit: $COMMIT_MSG"
        git commit -m "$COMMIT_MSG"
        
        log_success "Commit created"
    else
        log_warning "No changes to commit"
    fi
    
    # Create annotated tag
    TAG_NAME="v$NEW_VERSION"
    TAG_MSG="Release version $NEW_VERSION"
    
    if git rev-parse "$TAG_NAME" > /dev/null 2>&1; then
        log_warning "Tag $TAG_NAME already exists"
    else
        log_info "Creating annotated tag: $TAG_NAME"
        git tag -a "$TAG_NAME" -m "$TAG_MSG"
        log_success "Tag created: $TAG_NAME"
    fi
fi

echo ""
log_success "Version updated: ${YELLOW}$CURRENT_VERSION${NC} → ${GREEN}$NEW_VERSION${NC}"
echo ""
