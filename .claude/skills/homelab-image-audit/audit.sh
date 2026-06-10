#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$(dirname "$0")")")")"
KB_DIR="$REPO_ROOT/docs/solutions"

# ---------------------------------------------------------------------------
# Type aliases — maps variant names to canonical type from KB filename.
# ---------------------------------------------------------------------------
declare -A TYPE_ALIASES
TYPE_ALIASES[redis]="redis-valkey"
TYPE_ALIASES[valkey]="redis-valkey"

# ---------------------------------------------------------------------------
# Auto-discover KB entries by scanning docs/solutions/.
# Parses the "Image patterns" section from each KB file and builds the
# pattern→type map. Skips base-images-root-generic.md (its patterns are
# fallbacks that would overwrite specific patterns).
# ---------------------------------------------------------------------------
declare -A IMAGE_PATTERNS
declare -A TYPE_TO_KB

_discover_kb() {
    local kb_file type_name pattern
    for kb_file in "$KB_DIR"/base-images-*.md; do
        [[ "$kb_file" == *"root-generic"* ]] && continue
        type_name=$(basename "$kb_file" .md | sed 's/^base-images-//')
        TYPE_TO_KB["$type_name"]="$(basename "$kb_file")"
        # Section-aware extraction: reads from "## Image patterns" to next
        # heading or EOF. Process substitution avoids pipeline subshell so
        # associative array assignments survive.
        # Patterns containing * (e.g., nginx:*) are glob-like hints in KB
        # docs; grep -qF treats * as literal, so we strip them to produce
        # usable substring patterns (nginx: → matches nginx:1.29 etc.).
        while read -r pattern; do
            IMAGE_PATTERNS["$pattern"]="$type_name"
        done < <(awk '/^## Image patterns/{flag=1; next} /^## /{flag=0} flag' "$kb_file" \
            | grep -oP '`\K[^`]+' | sed 's/\*//g')
    done
}
_discover_kb

# Build usage string from discovered types (plus aliases and "other")
_known_types() {
    local types=""
    for t in $(printf '%s\n' "${!TYPE_TO_KB[@]}" | sort); do
        types="${types}|$t"
    done
    for t in $(printf '%s\n' "${!TYPE_ALIASES[@]}" | sort); do
        types="${types}|$t"
    done
    echo "${types#|}|other"
}

# ---------------------------------------------------------------------------
# Non-interactive mode: --image <name> --type <type>
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--image" ]]; then
    IMAGE="${2:-}"
    TYPE="${4:-}"
    if [[ -z "$IMAGE" || -z "$TYPE" ]]; then
        echo "Usage: $0 --image <image-name> --type <$(_known_types)>"
        exit 1
    fi

    # Resolve alias (e.g., valkey → redis)
    [[ -n "${TYPE_ALIASES[$TYPE]:-}" ]] && TYPE="${TYPE_ALIASES[$TYPE]}"

    # --type other: generic root-image warning
    if [[ "$TYPE" == "other" ]]; then
        echo ""
        echo "=== Generic / Root Image ==="
        echo "Image: $IMAGE"
        echo ""
        echo "Recommendation:"
        echo "  drop: [ALL]"
        echo "  WARN: image entrypoint may use privilege-drop mechanisms (gosu, su-exec, su, chroot)."
        echo "  If it does, add: SETGID, SETUID."
        echo "  If runAsNonRoot: true or runAsUser is set, no capabilities needed."
        echo ""
        echo "  Always verify by checking the image's Dockerfile entrypoint."
        exit 0
    fi

    # Look up KB file via discovered map
    KB_FILE=""
    if [[ -n "${TYPE_TO_KB[$TYPE]:-}" ]]; then
        KB_FILE="$KB_DIR/${TYPE_TO_KB[$TYPE]}"
    fi
    if [[ -n "$KB_FILE" && -f "$KB_FILE" ]]; then
        echo ""
        cat "$KB_FILE"
        echo ""
        echo "---"
        echo "Run 'audit.sh' interactively for guided prompts."
    else
        echo "Unknown image type: $TYPE"
        echo "Known types: $(_known_types)"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------
echo ""
echo "=== homelab Image Audit ==="
echo ""

read -r -p "Image name? " IMAGE
if [[ -z "$IMAGE" ]]; then
    echo "No image provided. Exiting."
    exit 1
fi

# Check image name against auto-discovered patterns
MATCHED_TYPE=""
for PATTERN in "${!IMAGE_PATTERNS[@]}"; do
    if echo "$IMAGE" | grep -qF "$PATTERN"; then
        MATCHED_TYPE="${IMAGE_PATTERNS[$PATTERN]}"
        break
    fi
done

if [[ -n "$MATCHED_TYPE" ]]; then
    echo ""
    echo "Detected image type: $MATCHED_TYPE"
    echo ""

    # For nginx, note derived-image context
    if [[ "$MATCHED_TYPE" == "nginx" ]]; then
        if echo "$IMAGE" | grep -qE "makeplane/plane-admin|makeplane/plane-frontend"; then
            echo "Note: This is a derived nginx image (nginx:1.29-alpine base)."
            echo "It uses non-privileged ports — NET_BIND_SERVICE not required."
            echo ""
        elif echo "$IMAGE" | grep -qE "leantime/leantime"; then
            echo "Note: leantime bundles nginx via serversideup/php but runs fully as non-root (UID 1000)."
            echo "No capabilities required despite bundling nginx."
            echo ""
        elif echo "$IMAGE" | grep -qE "ghcr.io/open-webui"; then
            echo "Note: Open WebUI bundles nginx internally. Capability needs are UNVERIFIED."
            echo "Check the Dockerfile entrypoint before setting securityContext."
            echo ""
        fi
    fi

    KB_FILE=""
    if [[ -n "${TYPE_TO_KB[$MATCHED_TYPE]:-}" ]]; then
        KB_FILE="$KB_DIR/${TYPE_TO_KB[$MATCHED_TYPE]}"
    fi
    if [[ -n "$KB_FILE" && -f "$KB_FILE" ]]; then
        cat "$KB_FILE"
    else
        echo "KB entry not found for type: $MATCHED_TYPE"
        echo "Falling back to generic recommendation."
    fi
else
    echo ""
    echo "No known pattern match for '$IMAGE'."
    echo ""
    echo "Base image type?"
    echo "  1) nginx"
    echo "  2) rabbitmq"
    echo "  3) redis / valkey"
    echo "  4) postgres"
    echo "  5) mysql / mariadb"
    echo "  6) mongodb"
    echo "  7) alpine / busybox"
    echo "  8) other"
    read -r -p "Choice [1-8]: " CHOICE

    case "$CHOICE" in
        1) TYPE="nginx" ;;
        2) TYPE="rabbitmq" ;;
        3) TYPE="redis" ;;
        4|5|6) TYPE="other" ;;
        7) TYPE="other" ;;
        8)
            echo ""
            echo "Entrypoint behavior?"
            echo "  1) Root-to-nonroot drop (uses gosu/su-exec/su)"
            echo "  2) Fully non-root (no privilege change at runtime)"
            echo "  3) Runs as root (no drop)"
            read -r -p "Choice [1-3]: " BEHAVIOR
            TYPE="other"
            ;;
        *) echo "Invalid choice. Exiting."; exit 1 ;;
    esac

    echo ""
    if [[ "$TYPE" != "other" ]]; then
        KB_FILE=""
        if [[ -n "${TYPE_TO_KB[$TYPE]:-}" ]]; then
            KB_FILE="$KB_DIR/${TYPE_TO_KB[$TYPE]}"
        fi
        if [[ -n "$KB_FILE" && -f "$KB_FILE" ]]; then
            cat "$KB_FILE"
        else
            echo "KB entry not found for type: $TYPE"
        fi
    else
        echo "=== Generic / Root Image ==="
        echo "Image: $IMAGE"
        echo ""
        if [[ "${BEHAVIOR:-}" == "1" ]]; then
            echo "Recommendation (root-to-nonroot drop detected):"
            echo "  drop: [ALL]"
            echo "  add: [SETGID, SETUID]"
            echo "  WARN: gosu/su-exec requires SETGID + SETUID to drop privileges."
            echo ""
            echo "Verify by checking the image's Dockerfile. If the image runs"
            echo "fully as non-root without a privilege drop, no capabilities needed."
        elif [[ "${BEHAVIOR:-}" == "2" ]]; then
            echo "Recommendation (fully non-root):"
            echo "  drop: [ALL]"
            echo "  No capabilities required. Set runAsNonRoot: true or runAsUser."
        else
            echo "Recommendation (runs as root):"
            echo "  drop: [ALL]"
            echo "  WARN: verify entrypoint for privilege-drop patterns (gosu, su-exec, su, chroot)."
            echo "  If any are found, add SETGID + SETUID."
            echo "  Set runAsUser or runAsNonRoot: true if the image supports non-root execution."
        fi
    fi
fi

echo ""
echo "---"
echo "Next: Set containerPort to match the image's EXPOSE directive."
echo "Next: Set fsGroup if using Longhorn PVCs (match the image's runtime GID)."
echo "Done."
