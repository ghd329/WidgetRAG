#!/usr/bin/env bash
# ===========================================================
# 기동 — `npm run prod`에 해당하는 단계 (멱등)
#
#   인프라(OpenSearch·Ollama+모델) → 이관 패키지 복원(있을 때만) → 앱 3종(AI 서버·백엔드·프론트)
#   → 합격 기준 검증 순서로 전체 스택을 올린다. DB는 SQLite 임베디드.
#   최초 실행은 모델(기본 gemma3:4b 3.3GB)·임베딩 모델(2.3GB) 다운로드로 오래 걸린다.
#
#   단계별 소요 시간을 마지막에 출력한다 — "새 환경에서 몇 분 걸리나"(이관 예상 시간)의 근거.
#   검증이 실패해도 요약까지는 출력하고, 종료코드로 결과를 알린다 (LexAI up.sh 와 같은 방식).
#   종료: ./stop.sh
# ===========================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TOTAL_START=$(date +%s)
PHASE_NAMES=(); PHASE_SECS=()
phase() {  # phase <이름> <명령...>
  local name="$1" t0
  shift
  t0=$(date +%s)
  "$@" || { printf '[widgetrag][FAIL] [%s] 실패 — 위 메시지를 확인하세요\n' "$name" >&2; exit 1; }
  PHASE_NAMES+=("$name"); PHASE_SECS+=("$(( $(date +%s) - t0 ))")
}

phase "인프라"      ./20-start-infra.sh
phase "패키지 복원" ./35-restore-package.sh
phase "앱"          ./40-start-apps.sh

VERIFY_RESULT=PASS
t0=$(date +%s)
./50-verify.sh || VERIFY_RESULT=FAIL
PHASE_NAMES+=("검증"); PHASE_SECS+=("$(( $(date +%s) - t0 ))")

echo
echo "== 요약 =="
for i in "${!PHASE_NAMES[@]}"; do
  printf '  %-12s %4d초\n' "${PHASE_NAMES[$i]}" "${PHASE_SECS[$i]}"
done
printf '  %-12s %4d초\n' "합계" "$(( $(date +%s) - TOTAL_START ))"
echo "  검증 결과 : $VERIFY_RESULT"
echo "  종료      : ./stop.sh"
[ "$VERIFY_RESULT" = PASS ]
