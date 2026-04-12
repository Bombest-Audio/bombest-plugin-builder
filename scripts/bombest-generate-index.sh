#!/bin/bash

#
# Bombest Plugin Builder - Static Site Index Generator
# Generates a clean, modern HTML index and builds.json API for all plugin builds
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

# Configuration
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
S3_BUCKET=$(jq -r '.s3_bucket' "$BUILD_CONFIG")
S3_REGION=$(jq -r '.s3_region' "$BUILD_CONFIG")
SITE_URL=$(jq -r '.site_url' "$BUILD_CONFIG")

# Validate required config values
if [[ -z "$PLUGIN_NAME" || "$PLUGIN_NAME" == "null" ]]; then
    log_error "plugin_name not configured in build.json"
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

log_info "Generating index for ${PLUGIN_NAME}"

# Create temporary directory for generated files
TEMP_DIR=$(mktemp -d -t bombest-index.XXXXXXXX)
trap "rm -rf '$TEMP_DIR'" EXIT

HTML_FILE="$TEMP_DIR/index.html"
JSON_FILE="$TEMP_DIR/builds.json"

# Declare arrays for tiers
declare -A TIER_VERSIONS
declare -A TIER_DATES
declare -A TIER_FORMATS
declare -A TIER_SHAS
declare -A TIER_LATEST
TIER_VERSIONS[release]=""
TIER_VERSIONS[alpha]=""
TIER_VERSIONS[dev]=""

# Scan S3 for all versions
log_info "Scanning S3 for builds..."

TIERS=("release" "alpha" "dev")
for tier in "${TIERS[@]}"; do
    log_info "  Scanning tier: $tier"

    # List all versions in this tier
    if versions=$(aws s3 ls "s3://${S3_BUCKET}/${PLUGIN_NAME}/${tier}/" \
        --region "$S3_REGION" 2>/dev/null | grep -E '^[[:space:]]+PRE' | awk '{print $2}' | sed 's/\/$//' | sort -V); then

        if [[ -z "$versions" ]]; then
            log_warn "    No versions found for tier: $tier"
            continue
        fi

        # Process versions in reverse order (newest first)
        version_array=($versions)
        for ((i=${#version_array[@]}-1; i>=0; i--)); do
            version="${version_array[$i]}"

            # Skip non-version directories
            if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                continue
            fi

            log_info "    Found version: $version"

            # Get manifest.json from S3
            manifest_url="s3://${S3_BUCKET}/${PLUGIN_NAME}/${tier}/${version}/manifest.json"
            manifest=$(mktemp)
            trap "rm -f '$manifest'" RETURN

            if aws s3 cp "$manifest_url" "$manifest" --region "$S3_REGION" >/dev/null 2>&1; then
                # Parse manifest
                date=$(jq -r '.date' "$manifest" 2>/dev/null || echo "unknown")
                git_sha=$(jq -r '.git_sha' "$manifest" 2>/dev/null || echo "unknown")
                formats=$(jq -r '.formats | map(.format) | join(", ")' "$manifest" 2>/dev/null || echo "unknown")

                # Store in arrays
                if [[ -z "${TIER_VERSIONS[$tier]}" ]]; then
                    TIER_VERSIONS[$tier]="$version"
                    TIER_LATEST[$tier]="$version"
                fi
                TIER_VERSIONS[$tier]+=",$version"
                TIER_DATES["${tier}_${version}"]="$date"
                TIER_FORMATS["${tier}_${version}"]="$formats"
                TIER_SHAS["${tier}_${version}"]="$git_sha"
            else
                log_warn "    Could not read manifest for $version"
            fi
        done
    else
        log_warn "    Failed to list versions for tier: $tier"
    fi
done

# Clean up comma-prefixed version strings
for tier in "${TIERS[@]}"; do
    if [[ "${TIER_VERSIONS[$tier]}" == ,* ]]; then
        TIER_VERSIONS[$tier]="${TIER_VERSIONS[$tier]:1}"
    fi
done

log_success "Scan complete"

# Generate HTML
log_info "Generating HTML index..."

GENERATION_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

cat > "$HTML_FILE" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Plugin Builds</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        html, body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            color: #333;
            background: #fafafa;
            line-height: 1.6;
        }

        header {
            background: white;
            border-bottom: 1px solid #e0e0e0;
            padding: 2rem 1rem;
            box-shadow: 0 1px 3px rgba(0,0,0,0.05);
        }

        .container {
            max-width: 900px;
            margin: 0 auto;
            padding: 0 1rem;
        }

        h1 {
            font-size: 2rem;
            font-weight: 600;
            margin-bottom: 0.5rem;
        }

        .subtitle {
            color: #666;
            font-size: 0.95rem;
        }

        main {
            padding: 2rem 1rem;
        }

        .tier-section {
            margin-bottom: 2.5rem;
        }

        .tier-header {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            margin-bottom: 1.5rem;
            padding-bottom: 0.75rem;
            border-bottom: 2px solid #e0e0e0;
        }

        .tier-header h2 {
            font-size: 1.4rem;
            font-weight: 600;
            margin: 0;
        }

        .tier-badge {
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .tier-release {
            background: #e8f5e9;
            color: #2e7d32;
            border-left: 3px solid #4caf50;
        }

        .tier-release .tier-badge {
            background: #4caf50;
            color: white;
        }

        .tier-alpha {
            background: #fff3e0;
            color: #e65100;
            border-left: 3px solid #ff9800;
        }

        .tier-alpha .tier-badge {
            background: #ff9800;
            color: white;
        }

        .tier-dev {
            background: #f5f5f5;
            color: #424242;
            border-left: 3px solid #9e9e9e;
        }

        .tier-dev .tier-badge {
            background: #9e9e9e;
            color: white;
        }

        .versions-list {
            list-style: none;
        }

        .version-item {
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 6px;
            padding: 1rem;
            margin-bottom: 0.75rem;
            transition: box-shadow 0.2s ease;
        }

        .version-item:hover {
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        }

        .version-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 0.75rem;
            flex-wrap: wrap;
            gap: 0.5rem;
        }

        .version-number {
            font-size: 1.1rem;
            font-weight: 600;
            color: #1976d2;
        }

        .latest-badge {
            display: inline-block;
            background: #1976d2;
            color: white;
            padding: 0.25rem 0.6rem;
            border-radius: 3px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
        }

        .version-meta {
            font-size: 0.9rem;
            color: #666;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
        }

        .meta-item {
            display: flex;
            flex-direction: column;
        }

        .meta-label {
            font-weight: 600;
            color: #999;
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.3px;
            margin-bottom: 0.25rem;
        }

        .meta-value {
            color: #333;
            word-break: break-all;
        }

        .version-link {
            display: inline-block;
            margin-top: 0.75rem;
            padding: 0.5rem 1rem;
            background: #1976d2;
            color: white;
            text-decoration: none;
            border-radius: 4px;
            font-size: 0.9rem;
            font-weight: 500;
            transition: background 0.2s ease;
        }

        .version-link:hover {
            background: #1565c0;
        }

        footer {
            background: white;
            border-top: 1px solid #e0e0e0;
            padding: 2rem 1rem;
            text-align: center;
            color: #999;
            font-size: 0.9rem;
            margin-top: 3rem;
        }

        .empty-state {
            text-align: center;
            padding: 2rem;
            color: #999;
            background: white;
            border-radius: 6px;
            border: 1px dashed #e0e0e0;
        }

        @media (max-width: 600px) {
            h1 {
                font-size: 1.5rem;
            }

            .version-meta {
                grid-template-columns: 1fr;
            }

            .tier-header {
                flex-direction: column;
                align-items: flex-start;
            }
        }
    </style>
</head>
<body>
    <header>
        <div class="container">
            <h1>Plugin Builds</h1>
            <p class="subtitle">Download and access plugin releases across all tiers</p>
        </div>
    </header>

    <main>
        <div class="container">
            <!-- Content will be inserted here -->
        </div>
    </main>

    <footer>
        Generated on <span id="gen-time"></span>
    </footer>

    <script>
        document.getElementById('gen-time').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
HTMLEOF

# Now we'll use a temp file to build the tiers HTML and insert it
TIERS_HTML="$TEMP_DIR/tiers.html"
> "$TIERS_HTML"

for tier in "${TIERS[@]}"; do
    if [[ -z "${TIER_VERSIONS[$tier]}" ]]; then
        continue
    fi

    TIER_CLASS="tier-${tier}"

    cat >> "$TIERS_HTML" <<EOF
            <section class="tier-section $TIER_CLASS">
                <div class="tier-header">
                    <h2>${tier^}</h2>
                    <span class="tier-badge">${tier}</span>
                </div>
                <ul class="versions-list">
EOF

    # Parse versions and iterate in order (already sorted newest first from S3)
    IFS=',' read -ra VERSIONS_ARRAY <<< "${TIER_VERSIONS[$tier]}"
    for version in "${VERSIONS_ARRAY[@]}"; do
        if [[ -z "$version" ]]; then
            continue
        fi

        date="${TIER_DATES[${tier}_${version}]:-unknown}"
        formats="${TIER_FORMATS[${tier}_${version}]:-unknown}"
        sha="${TIER_SHAS[${tier}_${version}]:-unknown}"

        # Format the date for display
        if [[ "$date" != "unknown" ]]; then
            display_date=$(date -d "$date" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$date")
        else
            display_date="unknown"
        fi

        # Determine if this is the latest version for this tier
        LATEST_MARKER=""
        if [[ "$version" == "${TIER_LATEST[$tier]}" ]]; then
            LATEST_MARKER="<span class=\"latest-badge\">Latest</span>"
        fi

        cat >> "$TIERS_HTML" <<EOF
                    <li class="version-item">
                        <div class="version-header">
                            <span class="version-number">v${version}</span>
                            $LATEST_MARKER
                        </div>
                        <div class="version-meta">
                            <div class="meta-item">
                                <span class="meta-label">Released</span>
                                <span class="meta-value">$display_date</span>
                            </div>
                            <div class="meta-item">
                                <span class="meta-label">Formats</span>
                                <span class="meta-value">$formats</span>
                            </div>
                            <div class="meta-item">
                                <span class="meta-label">Git SHA</span>
                                <span class="meta-value" title="$sha">${sha:0:8}</span>
                            </div>
                        </div>
                        <a href="s3://${S3_BUCKET}/${PLUGIN_NAME}/${tier}/${version}/" class="version-link">View Files</a>
                    </li>
EOF
    done

    cat >> "$TIERS_HTML" <<EOF
                </ul>
            </section>

EOF
done

# Check if we have any tiers
if [[ ! -s "$TIERS_HTML" ]] || [[ "$(grep -c 'version-item' "$TIERS_HTML" || true)" == "0" ]]; then
    cat >> "$TIERS_HTML" <<EOF
            <div class="empty-state">
                <p>No builds available yet. Deploy your first build using the deployment script.</p>
            </div>
EOF
fi

# Insert tiers HTML into the main template
sed -i "/<div class=\"container\">/r $TIERS_HTML" "$HTML_FILE"

log_success "HTML index generated"

# Generate JSON API file
log_info "Generating builds.json API..."

cat > "$JSON_FILE" <<'JSONEOF'
{
  "plugin_name": "",
  "generated_at": "",
  "tiers": {}
}
JSONEOF

# Build JSON structure
JSON_TIERS="{"
first_tier=true
for tier in "${TIERS[@]}"; do
    if [[ -z "${TIER_VERSIONS[$tier]}" ]]; then
        continue
    fi

    if [[ "$first_tier" == false ]]; then
        JSON_TIERS+=","
    fi

    JSON_TIERS+="\"$tier\": ["
    first_ver=true
    IFS=',' read -ra VERSIONS_ARRAY <<< "${TIER_VERSIONS[$tier]}"
    for version in "${VERSIONS_ARRAY[@]}"; do
        if [[ -z "$version" ]]; then
            continue
        fi

        if [[ "$first_ver" == false ]]; then
            JSON_TIERS+=","
        fi

        date="${TIER_DATES[${tier}_${version}]:-unknown}"
        formats="${TIER_FORMATS[${tier}_${version}]:-unknown}"
        sha="${TIER_SHAS[${tier}_${version}]:-unknown}"

        # Build formats array
        formats_json="["
        fmt_first=true
        IFS=',' read -ra FORMAT_ARRAY <<< "$formats"
        for fmt in "${FORMAT_ARRAY[@]}"; do
            fmt=$(echo "$fmt" | xargs) # trim whitespace
            if [[ ! -z "$fmt" ]]; then
                if [[ "$fmt_first" == false ]]; then
                    formats_json+=","
                fi
                formats_json+="\"$fmt\""
                fmt_first=false
            fi
        done
        formats_json+="]"

        JSON_TIERS+="{\"version\":\"$version\",\"date\":\"$date\",\"formats\":$formats_json,\"git_sha\":\"$sha\"}"
        first_ver=false
    done
    JSON_TIERS+="]"
    first_tier=false
done
JSON_TIERS+="}"

# Create final JSON
jq -n \
    --arg plugin "$PLUGIN_NAME" \
    --arg generated "$GENERATION_TIME" \
    --argjson tiers "$JSON_TIERS" \
    '{plugin_name: $plugin, generated_at: $generated, tiers: $tiers}' > "$JSON_FILE"

log_success "builds.json API generated"

# Upload to S3
log_info "Uploading to S3..."

if aws s3 cp "$HTML_FILE" "s3://${S3_BUCKET}/index.html" \
    --region "$S3_REGION" \
    --content-type "text/html; charset=utf-8" \
    --metadata "generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null 2>&1; then
    log_success "index.html uploaded"
else
    log_error "Failed to upload index.html"
    exit 1
fi

if aws s3 cp "$JSON_FILE" "s3://${S3_BUCKET}/builds.json" \
    --region "$S3_REGION" \
    --content-type "application/json; charset=utf-8" \
    --metadata "generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null 2>&1; then
    log_success "builds.json uploaded"
else
    log_error "Failed to upload builds.json"
    exit 1
fi

log_success "Site index generation complete!"
log_info "Index URL: ${SITE_URL}/index.html"
log_info "API URL: ${SITE_URL}/builds.json"

exit 0
