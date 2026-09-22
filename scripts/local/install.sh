#!/usr/bin/env bash
# ===========================================================
# 설치 — `npm install`에 해당하는 단계 (최초 1회, 멱등)
#
#   도구 설치(JDK·Python·Docker·Ollama) + 백엔드 설정 파일 생성.
#   서비스는 아무것도 띄우지 않는다. 기동은 ./start.sh
# ===========================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./10-install-tools.sh
./30-setup-config.sh

echo
echo "[widgetrag] 설치 완료 — 기동: ./start.sh"
