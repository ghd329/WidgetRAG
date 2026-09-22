#!/usr/bin/env bash
# ===========================================================
# 기동 상태 점검 — 6개 구성요소 헬스 체크 (+ 선택: 챗봇 스모크 테스트)
#
#   사용법:
#     ./50-verify.sh                          # 서비스 헬스만
#     CLIENT_CODE=shop_xxxx ./50-verify.sh    # RAG 챗봇 E2E 스모크 테스트까지
# ===========================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

PASS=0; FAIL=0
check() {  # $1=이름 $2=명령...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]   %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n' "$name"; FAIL=$((FAIL+1))
  fi
}

echo "== WidgetRAG 상태 점검 (INFRA_MODE=$INFRA_MODE) =="
# SQLite는 서버가 아니라 파일 — 백엔드 최초 기동 시 자동 생성된다
check "SQLite DB    ($SQLITE_DB_FILE)"   test -s "$SQLITE_DB_FILE"
check "OpenSearch   (:$PORT_OPENSEARCH)" curl -fsS --max-time 5 "http://localhost:$PORT_OPENSEARCH/_cluster/health"
check "Ollama       (:$PORT_OLLAMA)"     curl -fsS --max-time 5 "http://localhost:$PORT_OLLAMA/api/tags"
check "모델 $OLLAMA_MODEL"               sh -c "ollama list | awk '{print \$1}' | grep -Fqx '$OLLAMA_MODEL'"
check "AI 서버      (:$PORT_AI)"         curl -fsS --max-time 5 "http://localhost:$PORT_AI/docs"
check "백엔드       (:$PORT_BACKEND)"    curl -fsSL --max-time 10 "http://localhost:$PORT_BACKEND/swagger-ui.html"
check "프론트엔드   (:$PORT_FRONTEND)"   curl -fsS --max-time 5 "http://localhost:$PORT_FRONTEND/"

echo
echo "결과: 통과 $PASS / 실패 $FAIL"

# ---------- 선택: RAG 챗봇 스모크 테스트 ----------
if [ -n "${CLIENT_CODE:-}" ]; then
  QUESTION="${QUESTION:-가장 비싼 상품 추천해줘}"
  echo
  echo "== 챗봇 스모크 테스트 (clientCode=$CLIENT_CODE) =="
  echo "질문: $QUESTION"
  echo "(LLM 생성까지 최대 3분 대기 — CPU/Metal 환경은 수십 초 걸릴 수 있음)"
  START=$(date +%s)
  RESP=$(curl -fsS --max-time 200 -X POST "http://localhost:$PORT_BACKEND/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"clientCode\":\"$CLIENT_CODE\",\"question\":\"$QUESTION\"}") || { echo "[FAIL] /api/chat 호출 실패"; exit 1; }
  ELAPSED=$(( $(date +%s) - START ))
  echo "응답 (${ELAPSED}s):"
  echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
fi

[ "$FAIL" -eq 0 ]
