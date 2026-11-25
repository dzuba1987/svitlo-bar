#!/bin/bash
# Збирає й публікує реліз на GitHub (тег vVERSION). Потрібен gh: brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
NOTES="${1:-}"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Тег v$VERSION вже існує — підніміть версію у файлі VERSION" >&2
    exit 1
fi

./build.sh
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" dist/SvitloBar.zip --title "SvitloBar $VERSION" --notes "${NOTES:-Оновлення $VERSION}"
echo "Опубліковано v$VERSION — у друзів зʼявиться «Встановити оновлення» протягом 6 годин"
