#!/usr/bin/env bash
# ===========================================================
# [Phase D+E+F] 앱 계층 기동 — AI 서버(venv) → 백엔드(java -jar) → 프론트엔드(nginx)
#
#   기동 방식 (마이그레이션 식별 요건에 맞춤):
#     systemd 유닛 3종(widgetrag-ai/backend/frontend) + EnvironmentFile
#     → 이관 도구가 식별해야 할 "실행 파일(ExecStart)·환경변수(EnvironmentFile)"가
#       표준 위치(/etc/systemd/system, /etc/widgetrag/widgetrag.env)에 드러난다
#
#   - 여러 번 실행해도 안전(멱등) — 유닛/환경파일은 매번 재생성 후 재기동
#   - 백엔드는 ./mvnw package 후 java -jar 실행
#   - 옵션: --rebuild  (백엔드 jar 강제 재빌드)
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

REBUILD="${1:-}"

# ---------- 사전 점검 (인프라) ----------
# 관계형 DB는 SQLite 임베디드(백엔드가 파일로 직접 접근)라 사전 기동 점검 대상이 아님
port_listening "$PORT_OPENSEARCH" || die "OpenSearch(:$PORT_OPENSEARCH) 미기동 — ./20-start-infra.sh 먼저"
port_listening "$PORT_OLLAMA"     || die "Ollama(:$PORT_OLLAMA) 미기동 — ./20-start-infra.sh 먼저"
[ -f "$BACKEND_DIR/src/main/resources/application-local.yaml" ] || die "설정 파일 없음 — ./30-setup-config.sh 먼저"

# ---------- 공통 준비 1. AI 서버 venv ----------
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "$PYTHON_BIN 없음 — 10-install-tools.sh 먼저 (3.14로 venv를 만들면 torch 설치 실패)"
if [ ! -x "$VENV_DIR/bin/python" ]; then
  log "venv 생성 ($PYTHON_BIN)"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi
log "AI 서버 의존성 설치 (변경 없으면 빠르게 통과)"
"$VENV_DIR/bin/pip" install -q -r "$AI_DIR/requirements_exaone.txt"

# ---------- 공통 준비 2. 백엔드 jar ----------
resolve_java
JAR="$(ls "$BACKEND_DIR"/target/backend-*.jar 2>/dev/null | head -1 || true)"
if [ -z "$JAR" ] || [ "$REBUILD" = "--rebuild" ]; then
  log "백엔드 빌드 (./mvnw package -DskipTests) — 최초 수 분 소요"
  ( cd "$BACKEND_DIR" && chmod +x mvnw && ./mvnw -q package -DskipTests )
  JAR="$(ls "$BACKEND_DIR"/target/backend-*.jar | head -1)"
fi

# =========================================================
# systemd 유닛 기동 (이관 대상 환경의 표준 형태)
# =========================================================
# ---- 환경변수 파일: 이관 도구의 "환경변수 식별" 표준 앵커 ----
log "환경변수 파일 생성: $WIDGETRAG_ENV_FILE (root:600 — 비밀값 포함)"
sudo mkdir -p "$(dirname "$WIDGETRAG_ENV_FILE")"
sudo tee "$WIDGETRAG_ENV_FILE" >/dev/null <<EOF
# WidgetRAG 서비스 환경변수 — scripts/local/40-start-apps.sh 가 생성
# 마이그레이션 도구가 식별·이전해야 할 환경변수의 표준 위치
ADMIN_EMAIL=$WIDGETRAG_ADMIN_EMAIL
ADMIN_PASSWORD=$WIDGETRAG_ADMIN_PASSWORD
OLLAMA_BASE_URL=http://localhost:$PORT_OLLAMA
OLLAMA_MODEL=$OLLAMA_MODEL
LLM_TEMPERATURE=$LLM_TEMPERATURE
TZ=$APP_TZ
EOF
# 빈 값을 쓰면 소비 측 파싱이 모호해지므로 지정된 경우에만 기록
[ -n "$LLM_SEED" ] && echo "LLM_SEED=$LLM_SEED" | sudo tee -a "$WIDGETRAG_ENV_FILE" >/dev/null
sudo chmod 600 "$WIDGETRAG_ENV_FILE"

# ---- 유닛 3종 생성 (매번 재생성 — 멱등) ----
log "systemd 유닛 생성: ${SYSTEMD_UNITS[*]}"
sudo tee /etc/systemd/system/widgetrag-ai.service >/dev/null <<EOF
[Unit]
Description=WidgetRAG AI Server (FastAPI/uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$AI_DIR
EnvironmentFile=$WIDGETRAG_ENV_FILE
ExecStart=$VENV_DIR/bin/uvicorn main_exaone:app --host 0.0.0.0 --port $PORT_AI
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/widgetrag-backend.service >/dev/null <<EOF
[Unit]
Description=WidgetRAG Backend (Spring Boot)
After=network-online.target widgetrag-ai.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$BACKEND_DIR
EnvironmentFile=$WIDGETRAG_ENV_FILE
ExecStart=$JAVA_HOME/bin/java -jar $JAR --spring.profiles.active=local
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- 프론트: frontend/nginx.conf 를 그대로 쓰고, 도커 전용 부분만 호스트 값으로 바꾼다 ----
# Docker Compose 형태와 같은 설정이라 화면·/api 프록시·업로드 타임아웃이 두 형태에서 같다.
#   - resolver 127.0.0.11 (도커 내장 DNS) 제거 — 업스트림이 IP 라 필요 없다
#   - http://backend:8080 → 127.0.0.1:$PORT_BACKEND · 웹 루트 → 저장소의 frontend/
#   - 저장소의 nginx.conf · Dockerfile 이 웹 루트에 같이 있으므로 내보내지 않는다
#     (컨테이너 이미지는 빌드 때 지운다 — frontend/Dockerfile)
command -v nginx >/dev/null 2>&1 || die "nginx 없음 — ./10-install-tools.sh 먼저"
if port_listening "$PORT_FRONTEND" && ! systemctl is-active --quiet widgetrag-frontend; then
  die "포트 :$PORT_FRONTEND 를 다른 프로세스가 쓰고 있음 — 배포판 nginx(sudo systemctl disable --now nginx) 또는 Docker Compose 형태를 먼저 내리세요"
fi
log "프론트 nginx 설정 생성: $FRONTEND_NGINX_CONF (원본 frontend/nginx.conf)"
{
  cat <<EOF
# scripts/local/40-start-apps.sh 가 frontend/nginx.conf 로부터 생성 — 직접 고치지 말 것
user $USER;
worker_processes auto;
pid /run/widgetrag-frontend.pid;
error_log stderr warn;

events { worker_connections 1024; }

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;
  access_log off;

EOF
  sed -e '/^resolver /d' \
      -e "s#http://backend:8080#http://127.0.0.1:$PORT_BACKEND#" \
      -e "s#^\( *\)root /usr/share/nginx/html;#\1root $FRONTEND_DIR;\n\1location ~ ^/(nginx\\\\.conf|Dockerfile)\$ { return 404; }#" \
      -e "s#^\( *\)listen 80;#\1listen $PORT_FRONTEND;#" \
      "$FRONTEND_DIR/nginx.conf" | sed 's/^/  /'
  echo "}"
} | sudo tee "$FRONTEND_NGINX_CONF" >/dev/null
sudo nginx -t -q -c "$FRONTEND_NGINX_CONF" || die "nginx 설정 검사 실패 — $FRONTEND_NGINX_CONF"

sudo tee /etc/systemd/system/widgetrag-frontend.service >/dev/null <<EOF
[Unit]
Description=WidgetRAG Frontend (nginx — 정적 화면 + /api 프록시)
After=network-online.target widgetrag-backend.service

[Service]
Type=simple
# master 는 root(80 포트 바인딩), worker 는 설정의 user($USER)로 돈다
ExecStartPre=/usr/sbin/nginx -t -q -c $FRONTEND_NGINX_CONF
ExecStart=/usr/sbin/nginx -c $FRONTEND_NGINX_CONF -g 'daemon off;'
ExecReload=/usr/sbin/nginx -c $FRONTEND_NGINX_CONF -s reload
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
for unit in "${SYSTEMD_UNITS[@]}"; do
  sudo systemctl enable --now "$unit" >/dev/null 2>&1 || true
  sudo systemctl restart "$unit"     # 환경/유닛 변경 반영
done

wait_for_http "http://localhost:$PORT_AI/docs"                "AI 서버"    600   # 최초 bge-m3 2.3GB 다운로드
wait_for_http "http://localhost:$PORT_BACKEND/swagger-ui.html" "백엔드"     180
wait_for_http "http://localhost:$PORT_FRONTEND/login/company-login.html" "프론트엔드" 30
wait_for_http "http://localhost:$PORT_FRONTEND/widget.js"      "프론트 /api 프록시" 30

echo
log "앱 계층 기동 완료 (systemd 유닛)"
echo "  관리자 계정       : $WIDGETRAG_ADMIN_EMAIL (비밀번호: 환경변수 미지정 시 $ADMIN_PW_FILE 에 자동 생성됨)"
echo "  [로컬 PC] 터널    : ssh -N -L 8081:localhost:$PORT_FRONTEND ubuntu@<IP>   (Docker Compose 형태와 같은 터널)"
echo "  콘솔(가입/로그인) : http://localhost:8081/login/company-signup.html"
echo "  데모샵(위젯)      : http://localhost:8081/demo-shop/demo-living.html?client=<발급코드>"
echo "  API 문서          : http://localhost:$PORT_BACKEND/swagger-ui.html  (VM 안에서 · 또는 -L 8080:localhost:8080)"
echo "  서비스 상태       : systemctl status widgetrag-{ai,backend,frontend}"
echo "  로그              : journalctl -u widgetrag-backend -f"
echo
log "다음: ./50-verify.sh 로 상태 점검"
