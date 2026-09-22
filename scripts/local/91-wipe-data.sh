#!/usr/bin/env bash
# ===========================================================
# 완전 삭제 — "완전 삭제 후 복구" 리허설용 (이관 패키지의 자족성 증명)
#
#   타겟에서 상태 데이터를 전부 지운 뒤 이관 패키지만으로 서비스가 되살아나는지
#   검증하기 위한 파괴 단계 (LexAI 병행 검증 2026-09-22에서 이식한 검증 항목).
#
#   삭제 대상:
#     - $STORAGE_DIR (SQLite DB + 업로드 파일)
#     - OpenSearch 색인 (/var/lib/opensearch/nodes)
#   유지 대상:
#     - Ollama 모델 (이관 대상 아님 — 재다운로드 가능하나 삭제할 이유 없음)
#     - scripts/local/.admin-password (이관된 DB의 기존 계정과 짝 — 지우면 로그인 불가)
#     - 소스코드·설정 스크립트, 스냅샷 리포지토리(/var/lib/opensearch/snapshots)
#
#   사용법:
#     ./91-wipe-data.sh --yes     # --yes 없이는 안내만 출력하고 아무것도 지우지 않는다
#
#   복구(= 검증 본론) 절차:
#     ./61-import-data.sh <데이터 아카이브>      # SQLite + 업로드 파일 (해시 재검증 포함)
#     ./63-import-index.sh <색인 아카이브>       # 색인 (방법③) — 방법②라면 CSV 재업로드
#     ./30-setup-config.sh --force && ./start.sh
#     RUNS=5 CLIENT_CODE=... ./50-verify.sh      # 반복 검증까지 통과해야 "복구 성공"
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ "${1:-}" != "--yes" ]; then
  cat <<EOF
[widgetrag] 완전 삭제 대상 (아직 아무것도 지우지 않았음):
  - $STORAGE_DIR  (SQLite DB + 업로드 파일)
  - /var/lib/opensearch/nodes  (색인 — 스냅샷 리포지토리는 유지)
유지: Ollama 모델, .admin-password, 소스코드

실행하려면: $0 --yes
EOF
  exit 1
fi

log "전체 종료 (데이터 삭제 전 정합 정지)"
"$SCRIPT_DIR/90-stop-all.sh" || true

# ---------- SQLite DB + 업로드 파일 ----------
if [ -d "$STORAGE_DIR" ]; then
  rm -rf "$STORAGE_DIR"
  log "삭제: $STORAGE_DIR (SQLite DB + 업로드 파일)"
else
  warn "$STORAGE_DIR 없음 — 건너뜀"
fi

# ---------- OpenSearch 색인 ----------
if [ -d /var/lib/opensearch/nodes ]; then
  sudo rm -rf /var/lib/opensearch/nodes
  log "삭제: /var/lib/opensearch/nodes (색인 — 스냅샷 리포지토리는 유지)"
fi

echo
log "완전 삭제 완료 — 이제 이관 패키지만으로 복구되는지 검증한다:"
echo "  ./61-import-data.sh <데이터 아카이브>"
echo "  ./63-import-index.sh <색인 아카이브>      # (방법②라면 기동 후 CSV 재업로드)"
echo "  ./30-setup-config.sh --force && ./start.sh"
echo "  RUNS=5 CLIENT_CODE=... ./50-verify.sh     # 반복 검증까지 통과 = 복구 성공"
