#!/usr/bin/env bash
# ===========================================================
# 합격 기준 검증 — Shell 설치형의 경로·포트를 채워 공용 검증(scripts/verify.sh)을 부른다
#
#   두 실행 형태가 같은 판정 코드 · 같은 결과표(~/widgetrag-run/results.csv)를 쓴다
#   (LexAI verify.sh 와 같은 기준). 판정 항목은 scripts/verify.sh 머리말 참고.
#
#   사용법:
#     ./50-verify.sh                              # 구성요소 · 프론트 · 인증 · 채팅 · 데이터 · 로그
#     FORM=aws-shell RUNS=5 ./50-verify.sh        # 결과표에 환경 이름 태깅 · 웜 응답 5회로 p50/p95
#     REPEAT=5 ./50-verify.sh                     # 검증 전체를 5회 연속 — 전 회차 PASS 여야 성공
#     CLIENT_CODE=shop_xxxx ./50-verify.sh        # 채팅할 회사 지정 (기본: 상품이 가장 많은 승인된 회사)
#     VERIFY_ADMIN_PASSWORD=<소스 비밀번호> ./50-verify.sh   # 이관된 DB 의 관리자 로그인까지 판정
#     EXPECT_TRIGGERS=0 ./50-verify.sh            # 트리거 수를 소스 값과 대조
# ===========================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# 이관 패키지를 복원한 환경이면 데이터가 없는 것을 실패로 본다
if [ -f "$PACKAGE_DIR/.restored" ]; then
  export REQUIRE_DATA="${REQUIRE_DATA:-1}"
fi

export RUNTIME=native
export PORT_FRONTEND STORAGE_DIR SQLITE_DB_FILE APP_TZ OLLAMA_MODEL
export ADMIN_EMAIL="$WIDGETRAG_ADMIN_EMAIL"
export LOCAL_ADMIN_PASSWORD="$WIDGETRAG_ADMIN_PASSWORD"
export FK_CONFIG_FILE="$BACKEND_DIR/src/main/resources/application-local.yaml"
exec bash "$PROJECT_ROOT/scripts/verify.sh" "$@"
