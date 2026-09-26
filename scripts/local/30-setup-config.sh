#!/usr/bin/env bash
# ===========================================================
# [Phase C] 백엔드 설정 파일 생성 — application-local.yaml
#
#   - example 파일을 복사하는 대신 필요한 값을 직접 생성한다.
#     (example에는 필수 프로퍼티 widget.script-base-url이 누락되어 있어
#      그대로 복사하면 기동이 실패한다 — 검증 과정에서 확인된 결함)
#   - 내용은 전부 env.sh 값에서 나오므로 매번 다시 만든다. 달라졌을 때만 기존 파일을
#     백업하고 바꾼다 (예전 버전이 만든 설정이 남아 새 값이 조용히 무시되는 것을 막는다 —
#     compose 쪽 .env 태그 무시 결함과 같은 계열). --force 는 호환용으로 받아 둔다.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET="$BACKEND_DIR/src/main/resources/application-local.yaml"
NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT

cat > "$NEW" <<EOF
# 이 파일은 scripts/local/30-setup-config.sh 가 생성했다 (로컬 shell 설치형 기동용)
spring:
  datasource:
    # SQLite 임베디드 DB — 별도 서버 불필요. 파일이 없으면 자동 생성된다.
    # foreign_keys=true: SQLite는 커넥션마다 켜야 FK가 강제됨 (PostgreSQL과의 등가 조건)
    url: jdbc:sqlite:$SQLITE_DB_FILE?journal_mode=WAL&busy_timeout=5000&foreign_keys=true
    driver-class-name: org.sqlite.JDBC

widgetrag:
  storage:
    base-path: $STORAGE_DIR
  cors:
    # 콘솔은 프론트(nginx)의 /api 프록시로 같은 오리진에서 부르지만, 터널 포트(8081)가
    # Host 헤더와 달라 교차 오리진으로 판정된다 — Docker Compose 형태의 .env 와 같은 값
    allowed-origins: $CORS_ALLOWED_ORIGINS

widget:
  # 임베드 스크립트 태그 발급 시 안내되는 widget.js 공개 URL (프론트가 backend 로 프록시)
  script-base-url: $PUBLIC_BASE_URL/widget.js
EOF

if [ -f "$TARGET" ] && cmp -s "$NEW" "$TARGET"; then
  log "설정 변경 없음: $TARGET"
else
  if [ -f "$TARGET" ]; then
    cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S)"
    warn "설정이 바뀌어 기존 파일을 백업하고 갱신함"
  fi
  cp "$NEW" "$TARGET"
  log "생성 완료: $TARGET"
fi

mkdir -p "$STORAGE_DIR"
log "업로드 저장 디렉토리 준비: $STORAGE_DIR"

log "Phase C 완료 — 다음: ./40-start-apps.sh"
