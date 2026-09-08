#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/root/None_cdn_configs"

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
    audit \
    README.md \
    .gitignore

if git diff --cached --quiet; then

    echo "Nothing to commit."
    exit 0

fi

MESSAGE="${1:-development checkpoint}"

git commit -m "$MESSAGE"

git push origin HEAD
