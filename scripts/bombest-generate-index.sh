#!/bin/bash

#
# Bombest Plugin Builder - Static Site Index Generator
# Generates a clean, modern HTML index and builds.json API for all plugin builds
# bash 3.2 compatible (no associative arrays, no ${var^} uppercase expansion)
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

# bash 3.2 compatible dynamic variable helpers.
# Keys are sanitized: dots → underscores, so "1.5.2" becomes "1_5_2".

# set_tier_data <tier> <version> <field> <value>
set_tier_data() {
    local key
    key="TIERDATA_${1}_${2//./_}_${3}"
    printf -v "$key" '%s' "$4"
}

# get_tier_data <tier> <version> <field>  (prints value or empty string)
get_tier_data() {
    local key val
    key="TIERDATA_${1}_${2//./_}_${3}"
    eval "val=\${${key}:-}"
    echo "$val"
}

# set_tier_var <tier> <field> <value>
set_tier_var() {
    local key tier_upper
    tier_upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    key="TIERVAR_${tier_upper}_${2}"
    printf -v "$key" '%s' "$3"
}

# get_tier_var <tier> <field>  (prints value or empty string)
get_tier_var() {
    local key tier_upper val
    tier_upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    key="TIERVAR_${tier_upper}_${2}"
    eval "val=\${${key}:-}"
    echo "$val"
}

# capitalize_first <string>
capitalize_first() {
    local first rest
    first=$(echo "${1:0:1}" | tr '[:lower:]' '[:upper:]')
    rest="${1:1}"
    echo "${first}${rest}"
}

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
        tier_vers=""
        tier_latest_set=false
        for ((i=${#version_array[@]}-1; i>=0; i--)); do
            version="${version_array[$i]}"

            # Skip non-version directories
            if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                continue
            fi

            log_info "    Found version: $version"

            # Get manifest.json from S3
            manifest=$(mktemp)

            if aws s3 cp "s3://${S3_BUCKET}/${PLUGIN_NAME}/${tier}/${version}/manifest.json" \
                "$manifest" --region "$S3_REGION" >/dev/null 2>&1; then
                # Parse manifest
                date_val=$(jq -r '.date' "$manifest" 2>/dev/null || echo "unknown")
                git_sha=$(jq -r '.git_sha' "$manifest" 2>/dev/null || echo "unknown")
                formats=$(jq -r '.formats | map(.format) | join(", ")' "$manifest" 2>/dev/null || echo "unknown")

                set_tier_data "$tier" "$version" "date" "$date_val"
                set_tier_data "$tier" "$version" "formats" "$formats"
                set_tier_data "$tier" "$version" "sha" "$git_sha"

                if [[ "$tier_latest_set" == false ]]; then
                    set_tier_var "$tier" "LATEST" "$version"
                    tier_latest_set=true
                fi

                if [[ -z "$tier_vers" ]]; then
                    tier_vers="$version"
                else
                    tier_vers="$tier_vers,$version"
                fi
            else
                log_warn "    Could not read manifest for $version"
            fi
            rm -f "$manifest"
        done

        set_tier_var "$tier" "VERSIONS" "$tier_vers"
    else
        log_warn "    Failed to list versions for tier: $tier"
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
HTMLEOF

# Build tier sections directly into the HTML file
has_any_versions=false

for tier in "${TIERS[@]}"; do
    tier_vers=$(get_tier_var "$tier" "VERSIONS")
    if [[ -z "$tier_vers" ]]; then
        continue
    fi

    has_any_versions=true
    tier_label=$(capitalize_first "$tier")

    cat >> "$HTML_FILE" <<EOF
            <section class="tier-section tier-${tier}">
                <div class="tier-header">
                    <h2>${tier_label}</h2>
                    <span class="tier-badge">${tier}</span>
                </div>
                <ul class="versions-list">
EOF

    tier_latest=$(get_tier_var "$tier" "LATEST")

    IFS=',' read -ra VERSIONS_ARRAY <<< "$tier_vers"
    for version in "${VERSIONS_ARRAY[@]}"; do
        [[ -z "$version" ]] && continue

        date_val=$(get_tier_data "$tier" "$version" "date")
        formats=$(get_tier_data "$tier" "$version" "formats")
        sha=$(get_tier_data "$tier" "$version" "sha")
        sha_short="${sha:0:8}"

        # Format the date for display (macOS date can't parse ISO8601 with -d; fall back gracefully)
        display_date="$date_val"

        # Determine if this is the latest version for this tier
        LATEST_MARKER=""
        if [[ "$version" == "$tier_latest" ]]; then
            LATEST_MARKER="<span class=\"latest-badge\">Latest</span>"
        fi

        cat >> "$HTML_FILE" <<EOF
                    <li class="version-item">
                        <div class="version-header">
                            <span class="version-number">v${version}</span>
                            ${LATEST_MARKER}
                        </div>
                        <div class="version-meta">
                            <div class="meta-item">
                                <span class="meta-label">Released</span>
                                <span class="meta-value">${display_date}</span>
                            </div>
                            <div class="meta-item">
                                <span class="meta-label">Formats</span>
                                <span class="meta-value">${formats}</span>
                            </div>
                            <div class="meta-item">
                                <span class="meta-label">Git SHA</span>
                                <span class="meta-value" title="${sha}">${sha_short}</span>
                            </div>
                        </div>
                        <a href="s3://${S3_BUCKET}/${PLUGIN_NAME}/${tier}/${version}/" class="version-link">View Files</a>
                    </li>
EOF
    done

    cat >> "$HTML_FILE" <<'EOF'
                </ul>
            </section>
EOF
done

if [[ "$has_any_versions" == false ]]; then
    cat >> "$HTML_FILE" <<'EOF'
            <div class="empty-state">
                <p>No builds available yet. Deploy your first build using the deployment script.</p>
            </div>
EOF
fi

cat >> "$HTML_FILE" <<'EOF'
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
EOF

log_success "HTML index generated"

# Generate JSON API file
log_info "Generating builds.json API..."

JSON_TIERS="{"
first_tier=true
for tier in "${TIERS[@]}"; do
    tier_vers=$(get_tier_var "$tier" "VERSIONS")
    if [[ -z "$tier_vers" ]]; then
        continue
    fi

    if [[ "$first_tier" == false ]]; then
        JSON_TIERS+=","
    fi

    JSON_TIERS+="\"$tier\": ["
    first_ver=true
    IFS=',' read -ra VERSIONS_ARRAY <<< "$tier_vers"
    for version in "${VERSIONS_ARRAY[@]}"; do
        [[ -z "$version" ]] && continue

        if [[ "$first_ver" == false ]]; then
            JSON_TIERS+=","
        fi

        date_val=$(get_tier_data "$tier" "$version" "date")
        formats=$(get_tier_data "$tier" "$version" "formats")
        sha=$(get_tier_data "$tier" "$version" "sha")

        # Build formats JSON array
        formats_json="["
        fmt_first=true
        IFS=', ' read -ra FORMAT_ARRAY <<< "$formats"
        for fmt in "${FORMAT_ARRAY[@]}"; do
            fmt="${fmt## }"; fmt="${fmt%% }"  # trim whitespace
            [[ -z "$fmt" ]] && continue
            if [[ "$fmt_first" == false ]]; then
                formats_json+=","
            fi
            formats_json+="\"$fmt\""
            fmt_first=false
        done
        formats_json+="]"

        JSON_TIERS+="{\"version\":\"$version\",\"date\":\"$date_val\",\"formats\":$formats_json,\"git_sha\":\"$sha\"}"
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
