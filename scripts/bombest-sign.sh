#!/bin/bash

################################################################################
# Code Signing Script for Audio Plugins (macOS)
# Reads signing configuration from build.json and signs plugin binaries
# Supports dev (unsigned), alpha (ad hoc), and release (full Developer ID)
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
TIER=""
FORMATS=""
VERIFY_ONLY=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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
Usage: $0 --tier <dev|alpha|release> [--formats <formats>] [--verify-only]

Required:
  --tier dev|alpha|release      Build tier for signing strategy

Optional:
  --formats FILTER              Comma-separated list of formats to sign
                                (e.g., VST3,AU,CLAP). If omitted, signs all.
  --verify-only                 Only verify existing signatures, don't sign

Examples:
  $0 --tier dev
  $0 --tier alpha --formats VST3,CLAP
  $0 --tier release --verify-only
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            TIER="$2"
            shift 2
            ;;
        --formats)
            FORMATS="$2"
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=true
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

# Validate tier argument
if [[ -z "$TIER" ]]; then
    log_error "Missing required argument: --tier"
    usage
    exit 1
fi

case "$TIER" in
    dev|alpha|release)
        ;;
    *)
        log_error "Invalid tier: $TIER. Must be dev, alpha, or release."
        exit 1
        ;;
esac

################################################################################
# Read Configuration from build.json
################################################################################

read_config() {
    local key="$1"
    jq -r ".${key}" "$CONFIG_FILE" 2>/dev/null || echo ""
}

SIGNING_IDENTITY_ADHOC=$(read_config "signing_identity_adhoc")
SIGNING_IDENTITY_FULL=$(read_config "signing_identity_full")
BUILD_DIR=$(read_config "build_dir")
PLUGIN_NAME=$(read_config "plugin_name")

if [[ -z "$BUILD_DIR" ]]; then
    log_error "Missing 'build_dir' in $CONFIG_FILE"
    exit 1
fi

if [[ ! -d "$BUILD_DIR" ]]; then
    log_error "Build directory does not exist: $BUILD_DIR"
    exit 1
fi

log_info "Configuration loaded from $CONFIG_FILE"
log_info "Build directory: $BUILD_DIR"
log_info "Tier: $TIER"

################################################################################
# Find Plugin Binaries
################################################################################

find_plugin_binaries() {
    local binaries=()

    # Search for plugin wrapper directories
    if [[ -d "$BUILD_DIR" ]]; then
        # VST3 bundles (.vst3)
        while IFS= read -r -d '' file; do
            binaries+=("$file/Contents/macOS/${PLUGIN_NAME}.vst3")
        done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name "*.vst3" -print0 2>/dev/null)

        # CLAP bundles (.clap)
        while IFS= read -r -d '' file; do
            binaries+=("$file/Contents/macOS/${PLUGIN_NAME}.clap")
        done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name "*.clap" -print0 2>/dev/null)

        # AU bundles (.component)
        while IFS= read -r -d '' file; do
            binaries+=("$file/Contents/macOS/${PLUGIN_NAME}")
        done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name "*.component" -print0 2>/dev/null)

        # AAX bundles (.aaxplugin)
        while IFS= read -r -d '' file; do
            binaries+=("$file/Contents/macOS/${PLUGIN_NAME}.aaxplugin")
        done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name "*.aaxplugin" -print0 2>/dev/null)

        # Standalone executable
        if [[ -f "$BUILD_DIR/${PLUGIN_NAME}" ]]; then
            binaries+=("$BUILD_DIR/${PLUGIN_NAME}")
        fi
    fi

    # Filter by format if specified
    if [[ -n "$FORMATS" ]]; then
        local filtered=()
        local IFS=','
        for format in $FORMATS; do
            format=$(echo "$format" | xargs) # trim whitespace
            for binary in "${binaries[@]}"; do
                if [[ "$binary" =~ \.$format($|/) ]] || [[ "$binary" =~ \.$format/ ]]; then
                    filtered+=("$binary")
                fi
            done
        done
        binaries=("${filtered[@]}")
    fi

    # Return only existing binaries
    for binary in "${binaries[@]}"; do
        if [[ -e "$binary" ]]; then
            echo "$binary"
        fi
    done
}

################################################################################
# Signing Functions
################################################################################

list_available_identities() {
    log_info "Available signing identities:"
    security find-identity -v -p codesigning || true
}

verify_signature() {
    local binary="$1"
    if codesign --verify --verbose "$binary" 2>&1 | grep -q "valid on disk"; then
        return 0
    else
        return 1
    fi
}

sign_binary() {
    local binary="$1"
    local identity="$2"

    log_info "Signing: $binary"

    # Check if identity is available
    if ! security find-identity -v -p codesigning | grep -q "$identity"; then
        log_error "Signing identity not found: $identity"
        list_available_identities
        return 1
    fi

    # Perform code signing
    if codesign \
        --force \
        --deep \
        --sign "$identity" \
        --options runtime \
        --timestamp \
        "$binary" 2>&1; then
        log_success "Signed: $binary"
        return 0
    else
        log_error "Failed to sign: $binary"
        return 1
    fi
}

verify_binary() {
    local binary="$1"

    log_info "Verifying: $binary"

    if ! codesign --verify --verbose "$binary" 2>&1; then
        log_error "Verification failed: $binary"
        return 1
    fi

    log_success "Verified: $binary"
    return 0
}

assess_binary() {
    local binary="$1"

    log_info "Assessing with Gatekeeper: $binary"

    if ! spctl --assess --type execute "$binary" 2>&1; then
        log_error "Gatekeeper assessment failed: $binary"
        return 1
    fi

    log_success "Gatekeeper assessment passed: $binary"
    return 0
}

################################################################################
# Main Signing Logic
################################################################################

main() {
    local binaries=()
    local signed_count=0
    local verified_count=0
    local failed_count=0

    # Find all plugin binaries
    while IFS= read -r binary; do
        binaries+=("$binary")
    done < <(find_plugin_binaries)

    if [[ ${#binaries[@]} -eq 0 ]]; then
        log_warning "No plugin binaries found in $BUILD_DIR"
        return 0
    fi

    log_info "Found ${#binaries[@]} plugin binary/bundle(s)"

    # Handle dev tier - no signing needed
    if [[ "$TIER" == "dev" ]]; then
        echo -e "${YELLOW}Dev builds are unsigned${NC}"
        return 0
    fi

    # Handle verify-only mode
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "Running verification-only mode..."
        for binary in "${binaries[@]}"; do
            if verify_binary "$binary"; then
                ((verified_count++))
            else
                ((failed_count++))
            fi
        done

        log_info "Verification summary: $verified_count of ${#binaries[@]} verified successfully"
        [[ $failed_count -eq 0 ]] && return 0 || return 1
    fi

    # Determine signing identity
    local identity=""
    if [[ "$TIER" == "alpha" ]]; then
        identity="$SIGNING_IDENTITY_ADHOC"
        if [[ -z "$identity" ]]; then
            log_error "Ad hoc signing identity not configured in build.json"
            log_info "Set 'signing_identity_adhoc' to use ad hoc signing (e.g., '-')"
            exit 1
        fi
    elif [[ "$TIER" == "release" ]]; then
        identity="$SIGNING_IDENTITY_FULL"
        if [[ -z "$identity" ]]; then
            log_error "Full Developer ID signing identity not configured in build.json"
            list_available_identities
            exit 1
        fi
    fi

    # Sign each binary
    for binary in "${binaries[@]}"; do
        if sign_binary "$binary" "$identity"; then
            if verify_binary "$binary"; then
                ((verified_count++))

                # For release tier, also run Gatekeeper assessment
                if [[ "$TIER" == "release" ]]; then
                    if assess_binary "$binary"; then
                        ((signed_count++))
                    else
                        ((failed_count++))
                    fi
                else
                    ((signed_count++))
                fi
            else
                ((failed_count++))
            fi
        else
            ((failed_count++))
        fi
    done

    # Print summary
    echo ""
    log_info "==============================================="
    log_info "Signing Summary"
    log_info "==============================================="
    log_info "Tier: $TIER"
    log_info "Total binaries: ${#binaries[@]}"
    log_success "Successfully signed: $signed_count"
    [[ $verified_count -gt 0 ]] && log_info "Verified: $verified_count"
    [[ $failed_count -gt 0 ]] && log_error "Failed: $failed_count"

    [[ $failed_count -eq 0 ]] && return 0 || return 1
}

# Run main function
main "$@"
exit $?
