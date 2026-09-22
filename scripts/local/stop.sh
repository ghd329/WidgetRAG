#!/usr/bin/env bash
# 종료 — 전체 스택을 역순으로 내린다 (데이터 유지). 상세는 90-stop-all.sh 참고.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./90-stop-all.sh "$@"
