#!/usr/bin/env bash
set -uo pipefail

PROJECT="/root/None_cdn_configs"

if [ "$#" -lt 2 ]; then

    echo "Usage:"
    echo "dev-audit-runner.sh STAGE command [args...]"

    exit 1
fi

STAGE="$1"
shift

STAMP="$(date '+%Y%m%d-%H%M%S')"

SAFE_STAGE="$(
    printf '%s' "$STAGE" |
    tr -cd 'A-Za-z0-9._-'
)"

[ -n "$SAFE_STAGE" ] || SAFE_STAGE="unknown"

LOG_DIR="$PROJECT/audit/terminal"

mkdir -p "$LOG_DIR"

RAW_LOG="$LOG_DIR/${STAMP}-${SAFE_STAGE}.raw"
SAFE_LOG="$LOG_DIR/${STAMP}-${SAFE_STAGE}.log"

START="$(date -Is)"

echo "===================================================="
echo "NoneCDN Development Audit"
echo "Stage: $STAGE"
echo "Started: $START"
echo "===================================================="

set +e

"$@" \
    > >(tee -a "$RAW_LOG") \
    2> >(tee -a "$RAW_LOG" >&2)

RC=$?

set -e

END="$(date -Is)"

# ----------------------------------------------------------
# REDACT COMMON SECRET PATTERNS
# ----------------------------------------------------------

sed -E \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1***REDACTED***/Ig' \
    -e 's/(token[=:][[:space:]]*)[^[:space:]&]+/\1***REDACTED***/Ig' \
    -e 's/(password[=:][[:space:]]*)[^[:space:]&]+/\1***REDACTED***/Ig' \
    -e 's/(api[_-]?key[=:][[:space:]]*)[^[:space:]&]+/\1***REDACTED***/Ig' \
    -e 's/(cookie:[[:space:]]*)[^[:space:]]+/\1***REDACTED***/Ig' \
    "$RAW_LOG" > "$SAFE_LOG"

rm -f "$RAW_LOG"

{
    echo
    echo "===================================================="
    echo "Finished: $END"
    echo "Exit code: $RC"
    echo "===================================================="
} >> "$SAFE_LOG"


cd "$PROJECT"

git add \
    src \
    modules \
    panel \
    api \
    migrations \
    services \
    installer \
    tests \
    docs \
    reports \
    scripts \
    config \
    python \
    reference \
    audit \
    README.md \
    .gitignore \
    2>/dev/null || true

if ! git diff --cached --quiet; then

    if [ "$RC" -eq 0 ]; then
        MESSAGE="dev: ${SAFE_STAGE} completed successfully"
    else
        MESSAGE="failure: ${SAFE_STAGE} exited with code ${RC}"
    fi

    git commit -m "$MESSAGE" || true

    git push origin HEAD || {
        echo "[WARNING] Git push failed."
        echo "[WARNING] Local commit preserved."
    }

else

    echo "[INFO] No Git changes to commit."

fi

exit "$RC"
