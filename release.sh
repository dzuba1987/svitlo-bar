#!/bin/bash
# Реліз робить GitHub Actions (.github/workflows/release.yml) на кожен push у main.
# Цей скрипт лише комітить зміни й пушить: ./release.sh "що змінилось"
set -euo pipefail
cd "$(dirname "$0")"

MESSAGE="${1:?Вкажіть опис змін: ./release.sh \"що змінилось\"}"

git add -A
git commit -m "$MESSAGE"
git push origin main
echo "Запушено. Реліз збирається: https://github.com/dzuba1987/svitlo-bar/actions"
