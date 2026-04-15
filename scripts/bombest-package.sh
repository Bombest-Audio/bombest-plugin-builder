#!/bin/bash

#
# Bombest Plugin Builder - Package Script
# Builds a signed macOS .pkg installer from the current build artifacts.
# Installs plugins to standard system locations.
# bash 3.2 compatible.
#

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_CONFIG="${PROJECT_ROOT}/build.json"

if [[ ! -f "$BUILD_CONFIG" ]]; then
    log_error "build.json not found at $BUILD_CONFIG"
    exit 1
fi

PLUGIN_NAME=$(jq -r '.plugin_name'           "$BUILD_CONFIG")
BUILD_DIR="${PROJECT_ROOT}/$(jq -r '.build_dir' "$BUILD_CONFIG")"
INSTALLER_IDENTITY=$(jq -r '.installer_identity' "$BUILD_CONFIG")
TIER=""
VERSION=""

usage() {
    echo "Usage: $0 --tier <dev|alpha|release> --version X.Y.Z"
    echo "  --tier     Build tier (affects signing)"
    echo "  --version  Semantic version string"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --tier)    TIER="$2";    shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$TIER" ]]    && log_error "Missing --tier"    && usage
[[ -z "$VERSION" ]] && log_error "Missing --version" && usage

if [[ "$TIER" != "dev" && "$TIER" != "alpha" && "$TIER" != "release" ]]; then
    log_error "Invalid tier: $TIER"; exit 1
fi

# Build product name matches what BBMPluginConfig sets (e.g. "Far Away 1.5.2-alpha")
if [[ "$TIER" == "release" ]]; then
    PRODUCT_NAME="${PLUGIN_NAME/FarAway/Far Away}"
else
    PRODUCT_NAME="Far Away ${VERSION}-${TIER}"
fi

ARTEFACTS_DIR="${BUILD_DIR}/FarAway_artefacts/Release"
if [[ ! -d "$ARTEFACTS_DIR" ]]; then
    log_error "Artefacts directory not found: $ARTEFACTS_DIR"
    log_error "Run bombest-build.sh first."
    exit 1
fi

log_info "Building installer for ${PRODUCT_NAME}"
log_info "Artefacts: $ARTEFACTS_DIR"

# Create temp workspace
WORK_DIR=$(mktemp -d -t bombest-pkg.XXXXXXXX)
trap "rm -rf '$WORK_DIR'" EXIT

PAYLOAD_ROOT="${WORK_DIR}/payload"
PKG_STAGE="${WORK_DIR}/pkgs"
mkdir -p "$PKG_STAGE"

# ── AU ──────────────────────────────────────────────────────────────────────
AU_SRC="${ARTEFACTS_DIR}/AU/${PRODUCT_NAME}.component"
if [[ -d "$AU_SRC" ]]; then
    AU_ROOT="${PAYLOAD_ROOT}/au"
    AU_DEST="${AU_ROOT}/Library/Audio/Plug-Ins/Components"
    mkdir -p "$AU_DEST"
    cp -r "$AU_SRC" "$AU_DEST/"
    pkgbuild \
        --root "$AU_ROOT" \
        --install-location "/" \
        --identifier "com.bombestaudio.FarAway.au" \
        --version "$VERSION" \
        "${PKG_STAGE}/FarAway-AU.pkg" >/dev/null
    log_success "Built AU component package"
else
    log_warn "AU bundle not found — skipping: $AU_SRC"
fi

# ── VST3 ────────────────────────────────────────────────────────────────────
VST3_SRC="${ARTEFACTS_DIR}/VST3/${PRODUCT_NAME}.vst3"
if [[ -d "$VST3_SRC" ]]; then
    VST3_ROOT="${PAYLOAD_ROOT}/vst3"
    VST3_DEST="${VST3_ROOT}/Library/Audio/Plug-Ins/VST3"
    mkdir -p "$VST3_DEST"
    cp -r "$VST3_SRC" "$VST3_DEST/"
    pkgbuild \
        --root "$VST3_ROOT" \
        --install-location "/" \
        --identifier "com.bombestaudio.FarAway.vst3" \
        --version "$VERSION" \
        "${PKG_STAGE}/FarAway-VST3.pkg" >/dev/null
    log_success "Built VST3 component package"
else
    log_warn "VST3 bundle not found — skipping: $VST3_SRC"
fi

# ── AAX ─────────────────────────────────────────────────────────────────────
AAX_SRC="${ARTEFACTS_DIR}/AAX/${PRODUCT_NAME}.aaxplugin"
if [[ -d "$AAX_SRC" ]]; then
    AAX_ROOT="${PAYLOAD_ROOT}/aax"
    AAX_DEST="${AAX_ROOT}/Library/Application Support/Avid/Audio/Plug-Ins"
    mkdir -p "$AAX_DEST"
    cp -r "$AAX_SRC" "$AAX_DEST/"
    pkgbuild \
        --root "$AAX_ROOT" \
        --install-location "/" \
        --identifier "com.bombestaudio.FarAway.aax" \
        --version "$VERSION" \
        "${PKG_STAGE}/FarAway-AAX.pkg" >/dev/null
    log_success "Built AAX component package"
else
    log_warn "AAX bundle not found — skipping: $AAX_SRC"
fi

# ── Standalone ──────────────────────────────────────────────────────────────
APP_SRC="${ARTEFACTS_DIR}/Standalone/${PRODUCT_NAME}.app"
if [[ -d "$APP_SRC" ]]; then
    APP_ROOT="${PAYLOAD_ROOT}/app"
    APP_DEST="${APP_ROOT}/Applications"
    mkdir -p "$APP_DEST"
    cp -r "$APP_SRC" "$APP_DEST/"
    pkgbuild \
        --root "$APP_ROOT" \
        --install-location "/" \
        --identifier "com.bombestaudio.FarAway.standalone" \
        --version "$VERSION" \
        "${PKG_STAGE}/FarAway-Standalone.pkg" >/dev/null
    log_success "Built Standalone component package"
else
    log_warn "Standalone app not found — skipping: $APP_SRC"
fi

# ── Check at least one component was built ───────────────────────────────────
pkg_count=$(find "$PKG_STAGE" -name "*.pkg" | wc -l | tr -d ' ')
if [[ "$pkg_count" -eq 0 ]]; then
    log_error "No component packages were built. Check that artefacts exist."
    exit 1
fi

# ── Distribution XML ─────────────────────────────────────────────────────────
DIST_XML="${WORK_DIR}/distribution.xml"
cat > "$DIST_XML" <<DISTEOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Far Away ${VERSION}</title>
    <organization>com.bombestaudio</organization>
    <domains enable_localSystem="true" enable_currentUserHome="false"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <choices-outline>
DISTEOF

for pkg in "$PKG_STAGE"/*.pkg; do
    base=$(basename "$pkg" .pkg)
    echo "        <line choice=\"${base}\"/>" >> "$DIST_XML"
done

cat >> "$DIST_XML" <<DISTEOF
    </choices-outline>
DISTEOF

for pkg in "$PKG_STAGE"/*.pkg; do
    base=$(basename "$pkg" .pkg)
    cat >> "$DIST_XML" <<DISTEOF
    <choice id="${base}" visible="true" enabled="true" selected="true">
        <pkg-ref id="${base}"/>
    </choice>
    <pkg-ref id="${base}">${base}.pkg</pkg-ref>
DISTEOF
done

echo "</installer-gui-script>" >> "$DIST_XML"

# ── productbuild ─────────────────────────────────────────────────────────────
UNSIGNED_PKG="${WORK_DIR}/FarAway-${VERSION}-${TIER}-unsigned.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --package-path "$PKG_STAGE" \
    "$UNSIGNED_PKG" >/dev/null
log_success "Built distribution package"

# ── Sign with Installer identity ─────────────────────────────────────────────
OUTPUT_DIR="${PROJECT_ROOT}/installer/output"
mkdir -p "$OUTPUT_DIR"
OUTPUT_PKG="${OUTPUT_DIR}/FarAway-${VERSION}-${TIER}.pkg"

if [[ -n "$INSTALLER_IDENTITY" && "$INSTALLER_IDENTITY" != "null" && "$TIER" != "dev" ]]; then
    log_info "Signing with: $INSTALLER_IDENTITY"
    productsign \
        --sign "$INSTALLER_IDENTITY" \
        "$UNSIGNED_PKG" \
        "$OUTPUT_PKG" >/dev/null
    log_success "Signed installer: $OUTPUT_PKG"
else
    cp "$UNSIGNED_PKG" "$OUTPUT_PKG"
    if [[ "$TIER" == "dev" ]]; then
        log_info "Dev tier — skipping installer signing"
    else
        log_warn "installer_identity not configured — producing unsigned package"
    fi
fi

# ── Verify ───────────────────────────────────────────────────────────────────
if pkgutil --check-signature "$OUTPUT_PKG" >/dev/null 2>&1; then
    log_success "Signature verified"
else
    log_warn "Signature check failed or package is unsigned"
fi

log_success "Installer ready: $OUTPUT_PKG"
echo "$OUTPUT_PKG"
