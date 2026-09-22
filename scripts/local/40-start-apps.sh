#!/usr/bin/env bash
# ===========================================================
# [Phase D+E+F] 앱 계층 기동 — AI 서버(venv) → 백엔드(java -jar) → 프론트엔드
#
#   기동 방식 (마이그레이션 식별 요건에 맞춤):
#     Linux : systemd 유닛 3종(widgetrag-ai/backend/frontend) + EnvironmentFile
#             → 이관 도구가 식별해야 할 "실행 파일(ExecStart)·환경변수(EnvironmentFile)"가
#               표준 위치(/etc/systemd/system, /etc/widgetrag/widgetrag.env)에 드러난다
#     macOS : nohup 백그라운드 (systemd 없음 — 로컬 검증 전용 경로)
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

if [ "$OS" = "Linux" ]; then
  # =========================================================
  # Linux — systemd 유닛 기동 (이관 대상 환경의 표준 형태)
  # =========================================================
  PYTHON3_BIN="$(command -v python3)"

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

  sudo tee /etc/systemd/system/widgetrag-frontend.service >/dev/null <<EOF
[Unit]
Description=WidgetRAG Frontend (static, python http.server)
After=network-online.target

[Service]
Type=simple
User=$USER
ExecStart=$PYTHON3_BIN -m http.server $PORT_FRONTEND --directory $FRONTEND_DIR
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
  wait_for_http "http://localhost:$PORT_FRONTEND/"               "프론트엔드" 30

else
  # =========================================================
  # macOS — nohup 백그라운드 (로컬 검증 전용, systemd 없음)
  # =========================================================
  # 1. AI 서버
  if port_listening "$PORT_AI"; then
    log "AI 서버 이미 실행 중 (:$PORT_AI)"
  else
    log "AI 서버 기동 (:$PORT_AI) — 최초 실행은 bge-m3 약 2.3GB 다운로드로 수 분 소요"
    ( cd "$AI_DIR" && \
      OLLAMA_MODEL="$OLLAMA_MODEL" LLM_TEMPERATURE="$LLM_TEMPERATURE" \
      ${LLM_SEED:+LLM_SEED="$LLM_SEED"} \
      nohup "$VENV_DIR/bin/uvicorn" main_exaone:app \
        --host 0.0.0.0 --port "$PORT_AI" > "$LOG_DIR/ai-server.log" 2>&1 & echo $! > "$PID_DIR/ai-server.pid" )
    wait_for_http "http://localhost:$PORT_AI/docs" "AI 서버" 600
  fi

  # 2. 백엔드
  if port_listening "$PORT_BACKEND"; then
    log "백엔드 이미 실행 중 (:$PORT_BACKEND)"
  else
    log "백엔드 기동 (:$PORT_BACKEND) — $JAR"
    ( cd "$BACKEND_DIR" && \
      ADMIN_EMAIL="$WIDGETRAG_ADMIN_EMAIL" ADMIN_PASSWORD="$WIDGETRAG_ADMIN_PASSWORD" \
      nohup "$JAVA_HOME/bin/java" -jar "$JAR" --spring.profiles.active=local \
        > "$LOG_DIR/backend.log" 2>&1 & echo $! > "$PID_DIR/backend.pid" )
    wait_for_http "http://localhost:$PORT_BACKEND/swagger-ui.html" "백엔드" 180
  fi

  # 3. 프론트엔드
  if port_listening "$PORT_FRONTEND"; then
    log "프론트엔드 이미 실행 중 (:$PORT_FRONTEND)"
  else
    log "프론트엔드 기동 (:$PORT_FRONTEND)"
    ( nohup python3 -m http.server "$PORT_FRONTEND" --directory "$FRONTEND_DIR" \
        > "$LOG_DIR/frontend.log" 2>&1 & echo $! > "$PID_DIR/frontend.pid" )
    wait_for_http "http://localhost:$PORT_FRONTEND/" "프론트엔드" 30
  fi
fi

echo
log "앱 계층 기동 완료 ($([ "$OS" = "Linux" ] && echo 'systemd 유닛' || echo 'nohup'))"
echo "  관리자 계정       : $WIDGETRAG_ADMIN_EMAIL (비밀번호: 환경변수 미지정 시 $ADMIN_PW_FILE 에 자동 생성됨)"
echo "  콘솔(가입/로그인) : http://localhost:$PORT_FRONTEND/login/company-signup.html"
echo "  데모샵(위젯)      : http://localhost:$PORT_FRONTEND/demo-shop/demo-living.html"
echo "  API 문서          : http://localhost:$PORT_BACKEND/swagger-ui.html"
if [ "$OS" = "Linux" ]; then
  echo "  서비스 상태       : systemctl status widgetrag-{ai,backend,frontend}"
  echo "  로그              : journalctl -u widgetrag-backend -f"
else
  echo "  로그              : $LOG_DIR/{ai-server,backend,frontend}.log"
fi
echo
log "다음: ./50-verify.sh 로 상태 점검"
