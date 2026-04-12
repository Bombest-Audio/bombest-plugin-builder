#!/bin/bash

################################################################################
# Notarization Script for Audio Plugins (macOS)
# Submits plugins for Apple notarization and staples the ticket
# Reads configuration from build.json
################################################################################

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

################################################################################
# Configuration & Validation
################################################################################

CONFIG_FILE="build.json"
NOTARIZATION_PATH=""
NOTARIZE_ALL=false
WAIT_FOR_COMPLETION=true
STAPLE_RESULT=true
TEMP_DIR=""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Cleanup function for temporary files
cleanup() {
    if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Ensure we can find build.json
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_info "Run this script from the project root directory"
    exit 1
fi

################################################################################
# Parse Command Line Arguments
################################################################################

usage() {
    cat << EOF
Usage: $0 [--path <plugin-path>] [--all] [--no-wait] [--no-staple]

Optional:
  --path <plugin-path>   Path to single plugin to notarize
  --all                  Notarize all built plugins (mutually exclusive with --path)
  --no-wait              Don't wait for notarization to complete
  --no-staple            Don't staple the notarization ticket
  --help, -h             Show this help message

Examples:
  $0 --path "build/MyPlugin.app"
  $0 --all --wait
  $0 --all --no-wait
  $0 --path "build/MyPlugin.app" --no-staple

Note: If neither --path nor --all is specified, you must provide --path.
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            NOTARIZATION_PATH="$2"
            shift 2
            ;;
        --all)
            NOTARIZE_ALL=true
            shift
            ;;
        --no-wait)
            WAIT_FOR_COMPLETION=false
            shift
            ;;
        --no-staple)
            STAPLE_RESULT=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate argument combinations
if [[ "$NOTARIZE_ALL" == true ]] && [[ -n "$NOTARIZATION_PATH" ]]; then
    log_error "Cannot use both --path and --all"
    usage
    exit 1
fi

if [[ "$NOTARIZE_ALL" == false ]] && [[ -z "$NOTARIZATION_PATH" ]]; then
    log_error "Must specify either --path or --all"
    usage
    exit 1
fi

################################################################################
# Read Configuration from build.json
################################################################################

read_config() {
    local key="$1"
    jq -r ".${key}" "$CONFIG_FILE" 2>/dev/null || echo ""
}

NOTARIZATION_KEYCHAIN_PROFILE=$(read_config "notarization_keychain_profile")
BUILD_DIR=$(read_config "build_dir")
PLUGIN_NAME=$(read_config "plugin_name")

if [[ -z "$NOTARIZATION_KEYCHAIN_PROFILE" ]]; then
    log_error "Missing 'notarization_keychain_profile' in $CONFIG_FILE"
    log_info "Configure your App Store Connect API key in Keychain:"
    log_info "  xcrun notarytool store-credentials <profile-name> --api-key <path-to-key> --api-issuer <issuer-uuid>"
    exit 1
fi

if [[ -z "$BUILD_DIR" ]]; then
    log_error "Missing 'build_dir' in $CONFIG_FILE"
    exit 1
fi

log_info "Configuration loaded from $CONFIG_FILE"
log_info "Keychain profile: $NOTARIZATION_KEYCHAIN_PROFILE"
log_info "Build directory: $BUILD_DIR"

################################################################################
# Create Temporary Directory
################################################################################

TEMP_DIR=$(mktemp -d)
log_info "Temporary directory: $TEMP_DIR"

################################################################################
# Find Plugin Binaries (for --all mode)
################################################################################

find_notarizable_binaries() {
    local binaries=()

    if [[ ! -d "$BUILD_DIR" ]]; then
        log_error "Build directory does not exist: $BUILD_DIR"
        return 1
    fi

    # Look for application bundles and plugin bundles
    while IFS= read -r -d '' file; do
        binaries+=("$file")
    done < <(find "$BUILD_DIR" -maxdepth 1 \( -type d -name "*.app" -o -name "*.vst3" -o -name "*.clap" -o -name "*.component" -o -name "*.aaxplugin" \) -print0 2>/dev/null)

    # Also check for standalone executable
    if [[ -f "$BUILD_DIR/${PLUGIN_NAME}" ]]; then
        binaries+=("$BUILD_DIR/${PLUGIN_NAME}")
    fi

    for binary in "${binaries[@]}"; do
        echo "$binary"
    done
}

################################################################################
# Notarization Functions
################################################################################

create_notarization_zip() {
    local source_path="$1"
    local output_zip="$2"

    if [[ ! -e "$source_path" ]]; then
        log_error "Source path does not exist: $source_path"
        return 1
    fi

    log_info "Creating zip archive: $output_zip"

    if ditto -c -k --keepParent "$source_path" "$output_zip" 2>&1; then
        local file_size=$(du -h "$output_zip" | cut -f1)
        log_success "Created zip: $output_zip ($file_size)"
        return 0
    else
        log_error "Failed to create zip archive"
        return 1
    fi
}

submit_for_notarization() {
    local zip_path="$1"
    local submission_id=""
    local start_time=$(date +%s)

    log_info "Submitting for notarization: $(basename "$zip_path")"
    log_info "This may take several minutes..."

    # Submit and capture output
    local output
    if output=$(xcrun notarytool submit "$zip_path" \
        --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" \
        ${WAIT_FOR_COMPLETION:+--wait} \
        2>&1); then

        # Extract submission ID from output
        submission_id=$(echo "$output" | grep -i "id:" | head -1 | awk '{print $NF}' || echo "")

        if [[ -z "$submission_id" ]]; then
            # Fallback: look for UUID pattern
            submission_id=$(echo "$output" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1 || echo "")
        fi

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        if [[ "$WAIT_FOR_COMPLETION" == true ]]; then
            log_success "Notarization completed in ${duration}s"
            echo "$submission_id"
            return 0
        else
            log_success "Notarization submitted (ID: $submission_id)"
            echo "$submission_id"
            return 0
        fi
    else
        log_error "Notarization submission failed"
        log_info "Attempting to fetch error log..."

        # Try to get more details
        if command -v xcrun &> /dev/null; then
            if [[ -n "$submission_id" ]]; then
                xcrun notarytool log "$submission_id" \
                    --keychain-profile "$NOTARIZATION_KEYCHAIN_PROFILE" 2>&1 || true
            fi
        fi
        return 1
    fi
}

staple_notarization() {
    local target_path="$1"

    if [[ ! -e "$target_path" ]]; then
        log_error "Target path does not exist: $target_path"
        return 1
    fi

    log_info "Stapling notarization ticket: $target_path"

    if xcrun stapler staple "$target_path" 2>&1; then
        log_success "Stapled: $target_path"
        return 0
    else
        log_error "Failed to staple notarization ticket"
        return 1
    fi
}

validate_staple() {
    local target_path="$1"

    if [[ ! -e "$target_path" ]]; then
        log_error "Target path does not exist: $target_path"
        return 1
    fi

    log_info "Validating notarization: $target_path"

    if xcrun stapler validate "$target_path" 2>&1; then
        log_success "Validation successful: $target_path"
        return 0
    else
        log_error "Validation failed: $target_path"
        return 1
    fi
}

################################################################################
# Main Notarization Logic
################################################################################

notarize_single() {
    local plugin_path="$1"
    local success=false

    log_info "==============================================="
    log_info "Notarizing: $(basename "$plugin_path")"
    log_info "==============================================="

    if [[ ! -e "$plugin_path" ]]; then
        log_error "Plugin not found: $plugin_path"
        return 1
    fi

    # Create zip archive
    local zip_file="$TEMP_DIR/$(basename "$plugin_path").zip"
    if ! create_notarization_zip "$plugin_path" "$zip_file"; then
        return 1
    fi

    # Submit for notarization
    local submission_id
    if ! submission_id=$(submit_for_notarization "$zip_file"); then
        return 1
    fi

    # Staple the result
    if [[ "$STAPLE_RESULT" == true ]]; then
        if ! staple_notarization "$plugin_path"; then
            log_warning "Stapling failed, but notarization may still be valid"
        fi

        # Validate
        if ! validate_staple "$plugin_path"; then
            log_warning "Validation failed for: $plugin_path"
            success=false
        else
            success=true
        fi
    else
        log_info "Skipping staple operation (--no-staple)"
        success=true
    fi

    # Cleanup zip file
    rm -f "$zip_file"

    if [[ "$success" == true ]]; then
        log_success "Notarization complete: $(basename "$plugin_path")"
        return 0
    else
        return 1
    fi
}

main() {
    local plugins_to_notarize=()
    local successful=0
    local failed=0
    local overall_start=$(date +%s)

    # Collect plugins to notarize
    if [[ "$NOTARIZE_ALL" == true ]]; then
        log_info "Scanning for plugin binaries..."
        while IFS= read -r plugin; do
            plugins_to_notarize+=("$plugin")
        done < <(find_notarizable_binaries)

        if [[ ${#plugins_to_notarize[@]} -eq 0 ]]; then
            log_error "No plugin binaries found in $BUILD_DIR"
            return 1
        fi
    else
        plugins_to_notarize+=("$NOTARIZATION_PATH")
    fi

    log_info "Will notarize ${#plugins_to_notarize[@]} plugin(s)"

    # Notarize each plugin
    for plugin in "${plugins_to_notarize[@]}"; do
        if notarize_single "$plugin"; then
            ((successful++))
        else
            ((failed++))
        fi
    done

    # Print summary
    local overall_end=$(date +%s)
    local overall_duration=$((overall_end - overall_start))
    local minutes=$((overall_duration / 60))
    local seconds=$((overall_duration % 60))

    echo ""
    log_info "==============================================="
    log_info "Notarization Summary"
    log_info "==============================================="
    log_info "Total plugins: ${#plugins_to_notarize[@]}"
    log_success "Successful: $successful"
    [[ $failed -gt 0 ]] && log_error "Failed: $failed"
    log_info "Total time: ${minutes}m ${seconds}s"

    [[ $failed -eq 0 ]] && return 0 || return 1
}

# Run main function
main "$@"
exit $?
