#!/usr/bin/env bash
# ===========================================================
# [Phase C] 백엔드 설정 파일 생성 — application-local.yaml
#
#   - example 파일을 복사하는 대신 필요한 값을 직접 생성한다.
#     (example에는 필수 프로퍼티 widget.script-base-url이 누락되어 있어
#      그대로 복사하면 기동이 실패한다 — 검증 과정에서 확인된 결함)
#   - 파일이 이미 있으면 건너뜀. 다시 만들려면 --force
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET="$BACKEND_DIR/src/main/resources/application-local.yaml"

if [ -f "$TARGET" ] && [ "${1:-}" != "--force" ]; then
  log "이미 존재함 — 건너뜀: $TARGET  (재생성: $0 --force)"
else
  [ -f "$TARGET" ] && cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S)" && warn "기존 파일 백업함"
  cat > "$TARGET" <<EOF
# 이 파일은 scripts/local/30-setup-config.sh 가 생성했다 (로컬 shell 설치형 기동용)
spring:
  datasource:
    # SQLite 임베디드 DB — 별도 서버 불필요. 파일이 없으면 자동 생성된다.
    url: jdbc:sqlite:$SQLITE_DB_FILE?journal_mode=WAL&busy_timeout=5000
    driver-class-name: org.sqlite.JDBC

widgetrag:
  storage:
    base-path: $STORAGE_DIR

widget:
  # 임베드 스크립트 태그 발급 시 안내되는 widget.js 공개 URL (백엔드 정적 리소스)
  script-base-url: http://localhost:$PORT_BACKEND/widget.js
EOF
  log "생성 완료: $TARGET"
fi

mkdir -p "$STORAGE_DIR"
log "업로드 저장 디렉토리 준비: $STORAGE_DIR"

log "Phase C 완료 — 다음: ./40-start-apps.sh"
