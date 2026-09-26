#!/usr/bin/env bash
# ===========================================================
# [이관] 패키지 복원 — 앱 첫 기동 전에 색인 · DB · 업로드 파일을 되살린다
#
#   백엔드는 기동할 때 색인이 없으면 빈 색인을, DB 가 없으면 빈 DB 와 관리자 계정을 만든다.
#   그래서 복원은 반드시 40-start-apps.sh 보다 먼저다 (start.sh 가 이 순서로 부른다).
#
#   사용법 (보통은 start.sh · bootstrap.sh 가 부른다)
#     SNAPSHOT_URI=s3://버킷/widgetrag/<시각> ./35-restore-package.sh   # 받아서 복원
#     ./35-restore-package.sh                                           # 이미 받아둔 $PACKAGE_DIR 로 복원
#
#   둘 다 없으면 아무것도 하지 않는다 — 데이터 없이 시작하는 새 환경은 정상 경로다.
#   이미 DB · 색인이 있으면 건너뛴다 (재실행 안전). 덮어쓰려면 FORCE_RESTORE=1.
#   패키지 형식은 두 형태 공용 — Docker Compose 에서 뜬 패키지도 그대로 복원된다 (scripts/package.sh).
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ -n "${SNAPSHOT_URI:-}" ]; then
  bash "$PACKAGE_SH" fetch "$SNAPSHOT_URI" "$PACKAGE_DIR"
fi
if [ ! -f "$PACKAGE_DIR/checksums.sha256" ]; then
  log "이관 패키지 없음 — 복원 건너뜀 (데이터 없이 시작)"
  exit 0
fi

# 덮어쓰기는 백엔드를 내린 상태에서만 안전하다 (실행 중인 DB 를 바꿔치면 -wal 이 새 파일에 섞인다)
if [ "${FORCE_RESTORE:-0}" = 1 ] && systemctl is-active --quiet widgetrag-backend; then
  log "FORCE_RESTORE=1 — 백엔드를 내리고 복원"
  sudo systemctl stop widgetrag-backend
fi

RUNTIME=native STORAGE_DIR="$STORAGE_DIR" bash "$PACKAGE_SH" restore "$PACKAGE_DIR" all

log "복원 단계 완료 — 다음: ./40-start-apps.sh (복원된 DB · 색인으로 기동)"
