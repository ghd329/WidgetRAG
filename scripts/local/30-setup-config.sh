#!/usr/bin/env bash
# ===========================================================
# [Phase C] 백엔드 설정 파일 생성 — /etc/widgetrag/application-local.yaml
#
#   - jar 밖(/etc/widgetrag/)에 둔다. 예전처럼 backend/src/main/resources 에 쓰면 Maven 이 jar 안에 구워 넣어
#     이 VM 의 절대 경로(DB · 업로드 경로)가 jar 에 박힌다 — 그 jar 는 다른 VM 으로 옮겨 쓸 수 없다.
#     백엔드 유닛이 --spring.config.additional-location 으로 읽으며, 같은 이름의 classpath 사본보다 우선한다.
#   - example 파일을 복사하는 대신 필요한 값을 직접 생성한다.
#     (example에는 필수 프로퍼티 widget.script-base-url이 누락되어 있어
#      그대로 복사하면 기동이 실패한다 — 검증 과정에서 확인된 결함)
#   - 내용은 전부 env.sh 값에서 나오므로 매번 다시 만든다. 달라졌을 때만 기존 파일을
#     백업하고 바꾼다 (예전 버전이 만든 설정이 남아 새 값이 조용히 무시되는 것을 막는다 —
#     compose 쪽 .env 태그 무시 결함과 같은 계열). --force 는 호환용으로 받아 둔다.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

TARGET="$APP_CONFIG_FILE"
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

server:
  servlet:
    session:
      cookie:
        # 콘솔 세션 쿠키 — Docker Compose 형태와 같은 값 (env.sh 의 SESSION_SECURE · SESSION_SAME_SITE).
        # HTTPS 없이 공인 IP 로 콘솔을 열어도 세션이 저장되게. HTTPS 를 붙이면 secure: true · same-site: none
        same-site: $SESSION_SAME_SITE
        secure: $SESSION_SECURE
EOF

if [ -f "$TARGET" ] && cmp -s "$NEW" "$TARGET"; then
  log "설정 변경 없음: $TARGET"
else
  if [ -f "$TARGET" ]; then
    sudo cp "$TARGET" "$TARGET.bak.$(date +%Y%m%d%H%M%S)"
    warn "설정이 바뀌어 기존 파일을 백업하고 갱신함"
  fi
  sudo install -D -m 644 -o root -g root "$NEW" "$TARGET"   # root:644 — 비밀값 없음, 백엔드(일반 사용자)가 읽는다
  log "생성 완료: $TARGET"
fi

# 예전 위치(소스 트리 안)에 남은 설정은 지운다 — 남겨 두면 다음 빌드 때 jar 에 다시 구워진다.
# 패키지로 전개한 트리에는 backend/src 자체가 없으므로 있을 때만.
OLD="$BACKEND_DIR/src/main/resources/application-local.yaml"
if [ -f "$OLD" ]; then
  rm -f "$OLD" "$OLD".bak.*
  warn "소스 트리 안의 구 설정 제거: $OLD — 이미 빌드된 jar 에 구워진 사본은 ./40-start-apps.sh --rebuild 로 없앤다"
fi

mkdir -p "$STORAGE_DIR"
log "업로드 저장 디렉토리 준비: $STORAGE_DIR"

log "Phase C 완료 — 다음: ./40-start-apps.sh"
