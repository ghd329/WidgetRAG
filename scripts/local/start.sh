#!/usr/bin/env bash
# ===========================================================
# 기동 — `npm run prod`에 해당하는 단계 (멱등)
#
#   인프라(OpenSearch·Ollama+모델) → 앱 3종(AI 서버·백엔드·프론트) — DB는 SQLite 임베디드
#   순서로 전체 스택을 올리고 헬스 체크까지 수행한다.
#   최초 실행은 모델(기본 gemma3:4b 3.3GB)·임베딩 모델(2.3GB) 다운로드로 오래 걸린다.
#   종료: ./stop.sh
# ===========================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./20-start-infra.sh
./40-start-apps.sh
./50-verify.sh
