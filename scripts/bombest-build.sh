#!/bin/bash

################################################################################
# Audio Plugin Builder Script
# Builds JUCE audio plugins using CMake with support for multiple formats
# 
# Usage:
#   ./build.sh [--formats FORMAT1,FORMAT2,...] [--config Release|Debug] [--clean]
#
# Examples:
#   ./build.sh                                    # Build all formats, Release
#   ./build.sh --formats VST3,CLAP                # Build specific formats
#   ./build.sh --config Debug --clean             # Clean build in Debug mode
################################################################################

set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Parse command line arguments
FORMATS="all"
CONFIG="Release"
CLEAN_BUILD=false
TIER="dev"

while [[ $# -gt 0 ]]; do
    case $1 in
        --formats)
            FORMATS="$2"
            shift 2
            ;;
        --config)
            CONFIG="$2"
            if [[ ! "$CONFIG" =~ ^(Release|Debug)$ ]]; then
                log_error "Invalid config: $CONFIG (must be Release or Debug)"
                exit 1
            fi
            shift 2
            ;;
        --tier)
            TIER="$2"
            if [[ ! "$TIER" =~ ^(dev|alpha|release)$ ]]; then
                log_error "Invalid tier: $TIER (must be dev, alpha, or release)"
                exit 1
            fi
            shift 2
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--formats FORMAT1,FORMAT2,...] [--config Release|Debug] [--tier dev|alpha|release] [--clean]"
            exit 1
            ;;
    esac
done

# Derive config from tier if not explicitly set
if [[ "$TIER" == "dev" && "$CONFIG" == "Release" ]]; then
    CONFIG="Debug"
fi

# Find project root (directory containing build.json)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Read configuration from build.json
log_info "Reading build configuration from build.json..."

PLUGIN_NAME=$(jq -r '.plugin_name' "$BUILD_CONFIG_FILE")
BUILD_DIR=$(jq -r '.build_dir' "$BUILD_CONFIG_FILE")
CMAKE_GENERATOR=$(jq -r '.cmake_generator' "$BUILD_CONFIG_FILE")
CMAKE_EXTRA_ARGS=$(jq -r '.cmake_extra_args // ""' "$BUILD_CONFIG_FILE")
DEFAULT_FORMATS=$(jq -r '.plugin_formats // "VST3,CLAP"' "$BUILD_CONFIG_FILE")

# Resolve paths relative to project root
if [[ ! "$BUILD_DIR" = /* ]]; then
    BUILD_DIR="$PROJECT_ROOT/$BUILD_DIR"
fi

# Use default formats if "all" is specified
if [[ "$FORMATS" == "all" ]]; then
    FORMATS="$DEFAULT_FORMATS"
fi

log_info "Plugin name: $PLUGIN_NAME"
log_info "Build directory: $BUILD_DIR"
log_info "CMake generator: $CMAKE_GENERATOR"
log_info "Build config: $CONFIG"
log_info "Formats: $FORMATS"

# Clean build directory if requested
if [[ "$CLEAN_BUILD" == true ]]; then
    if [[ -d "$BUILD_DIR" ]]; then
        log_info "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Determine number of parallel jobs
if [[ "$(uname)" == "Darwin" ]]; then
    NUM_JOBS=$(sysctl -n hw.ncpu)
else
    NUM_JOBS=$(nproc)
fi
log_info "Using $NUM_JOBS parallel jobs"

# Track build start time
BUILD_START=$(date +%s)

# CMake configure step
log_info "Running CMake configure..."
# Read version from CMakeLists.txt in the parent plugin project
PLUGIN_PROJECT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
BBM_VERSION=$(grep -m1 'project(.*VERSION' "$PLUGIN_PROJECT_ROOT/CMakeLists.txt" | sed 's/.*VERSION[[:space:]]*\([0-9.]*\).*/\1/')
if [[ -z "$BBM_VERSION" ]]; then
    BBM_VERSION="0.0.0"
fi

CMAKE_CMD="cmake -S \"$PLUGIN_PROJECT_ROOT\" -B \"$BUILD_DIR\" -G \"$CMAKE_GENERATOR\" -DCMAKE_BUILD_TYPE=\"$CONFIG\" -DBBM_BUILD_TYPE=\"$TIER\" -DBBM_VERSION=\"$BBM_VERSION\""

if [[ -n "$CMAKE_EXTRA_ARGS" ]]; then
    CMAKE_CMD="$CMAKE_CMD $CMAKE_EXTRA_ARGS"
fi

if ! eval "$CMAKE_CMD"; then
    log_error "CMake configuration failed"
    exit 1
fi

log_success "CMake configuration completed"

# Build step
log_info "Building plugin..."

# Convert comma-separated formats to array
IFS=',' read -ra FORMAT_ARRAY <<< "$FORMATS"

# Trim whitespace from format names
TRIMMED_FORMATS=()
for format in "${FORMAT_ARRAY[@]}"; do
    TRIMMED_FORMATS+=("$(echo "$format" | xargs)")
done

# Check if building all or specific formats
if [[ "${#TRIMMED_FORMATS[@]}" -eq 1 && "${TRIMMED_FORMATS[0]}" == "all" ]]; then
    # Build everything
    log_info "Building all targets..."
    if ! cmake --build "$BUILD_DIR" --config "$CONFIG" -j"$NUM_JOBS"; then
        log_error "Build failed"
        exit 1
    fi
else
    # Build specific format targets
    for format in "${TRIMMED_FORMATS[@]}"; do
        TARGET_NAME="${PLUGIN_NAME}_${format}"
        log_info "Building target: $TARGET_NAME..."
        if ! cmake --build "$BUILD_DIR" --config "$CONFIG" --target "$TARGET_NAME" -j"$NUM_JOBS"; then
            log_warning "Failed to build target: $TARGET_NAME"
        fi
    done
fi

log_success "Build completed"

# Find and report binaries
log_info "Scanning for produced binaries..."

# Define binary patterns
BINARY_PATTERNS=(
    "$BUILD_DIR/**/*.vst3"
    "$BUILD_DIR/**/*.clap"
    "$BUILD_DIR/**/*.component"
    "$BUILD_DIR/**/*.aaxplugin"
    "$BUILD_DIR/**/$(echo $PLUGIN_NAME | sed 's/_/ /g')"  # Standalone executable
    "$BUILD_DIR/**/${PLUGIN_NAME}"  # Standalone executable (underscore variant)
)

# Find all binaries and collect results
FOUND_BINARIES=()
TOTAL_SIZE=0

# Use find instead of glob for better portability
FIND_PATTERNS=(
    "-name '*.vst3'"
    "-name '*.clap'"
    "-name '*.component'"
    "-name '*.aaxplugin'"
)

for pattern in "${FIND_PATTERNS[@]}"; do
    while IFS= read -r -d '' binary; do
        if [[ -n "$binary" ]]; then
            FOUND_BINARIES+=("$binary")
        fi
    done < <(find "$BUILD_DIR" $pattern -print0 2>/dev/null || true)
done

# Look for standalone executable
if [[ -f "$BUILD_DIR/$PLUGIN_NAME" && -x "$BUILD_DIR/$PLUGIN_NAME" ]]; then
    FOUND_BINARIES+=("$BUILD_DIR/$PLUGIN_NAME")
elif [[ -f "$BUILD_DIR/$CONFIG/$PLUGIN_NAME" && -x "$BUILD_DIR/$CONFIG/$PLUGIN_NAME" ]]; then
    FOUND_BINARIES+=("$BUILD_DIR/$CONFIG/$PLUGIN_NAME")
fi

# Also check in build subdirectories
if [[ -d "$BUILD_DIR/$CONFIG" ]]; then
    while IFS= read -r -d '' binary; do
        if [[ -n "$binary" ]]; then
            FOUND_BINARIES+=("$binary")
        fi
    done < <(find "$BUILD_DIR/$CONFIG" \( -name '*.vst3' -o -name '*.clap' -o -name '*.component' -o -name '*.aaxplugin' \) -print0 2>/dev/null || true)
fi

if [[ ${#FOUND_BINARIES[@]} -eq 0 ]]; then
    log_warning "No binaries found (check build output for errors)"
else
    echo ""
    log_success "Found ${#FOUND_BINARIES[@]} binary(ies):"
    echo ""
    
    # Remove duplicates
    declare -A seen
    for binary in "${FOUND_BINARIES[@]}"; do
        if [[ -z "${seen[$binary]:-}" ]]; then
            seen["$binary"]=1
            
            # Get size and format nicely
            if [[ -d "$binary" ]]; then
                SIZE=$(du -sh "$binary" | cut -f1)
                TYPE=$(basename "$binary" | sed 's/.*\.//')
                echo -e "${GREEN}  ✓${NC} ${binary#$PROJECT_ROOT/} (${SIZE})"
            fi
        fi
    done
    
    echo ""
fi

# Calculate and report build time
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
MINUTES=$((BUILD_TIME / 60))
SECONDS=$((BUILD_TIME % 60))

echo ""
log_success "Build completed in ${MINUTES}m${SECONDS}s"
