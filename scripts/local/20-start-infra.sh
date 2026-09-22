#!/usr/bin/env bash
# ===========================================================
# [Phase B] 인프라 기동 — OpenSearch, Ollama + LLM 모델
#
#   - 관계형 DB는 SQLite 임베디드라 기동할 서버가 없다 (백엔드가 파일로 직접 접근)
#   - 컨테이너가 이미 존재하면 docker start (데이터 유지), 없으면 docker run
#   - 모델 pull 실패(사내망 차단) 시 HuggingFace 경유로 자동 폴백
#   - 여러 번 실행해도 안전(멱등)
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ "$INFRA_MODE" = "native" ]; then
  # =========================================================
  # 순수 네이티브 경로 (Track A / Linux 기본) — Docker 불필요
  # =========================================================
  log "OpenSearch 기동 (systemd)"
  sudo systemctl enable --now opensearch

  wait_for_http "http://localhost:$PORT_OPENSEARCH/_cluster/health" "OpenSearch" 120
else
  # =========================================================
  # 컨테이너 경로 (macOS 로컬 검증용)
  # =========================================================

# ---------- 0. 컨테이너 런타임 ----------
if [ "$OS" = "Darwin" ]; then
  if ! colima status >/dev/null 2>&1; then
    log "Colima VM 시작 (4 CPU / 8 GiB)"
    colima start --cpu 4 --memory 8
  else
    log "Colima 이미 실행 중"
  fi
fi
docker info >/dev/null 2>&1 || die "Docker 데몬에 연결 불가"

# ---------- 1. OpenSearch ----------
# 백엔드가 무인증 평문 HTTP로 접속하는 구조라 보안 플러그인을 끈다 (로컬 전용 — 외부 포트 노출 금지)
if docker ps --format '{{.Names}}' | grep -qx "$OS_CONTAINER"; then
  log "OpenSearch 이미 실행 중"
elif docker ps -a --format '{{.Names}}' | grep -qx "$OS_CONTAINER"; then
  log "OpenSearch 기존 컨테이너 시작 (색인 유지)"
  docker start "$OS_CONTAINER" >/dev/null
else
  log "OpenSearch 컨테이너 생성"
  docker run -d --name "$OS_CONTAINER" -p "$PORT_OPENSEARCH:9200" \
    -e discovery.type=single-node \
    -e DISABLE_SECURITY_PLUGIN=true \
    -e DISABLE_INSTALL_DEMO_CONFIG=true \
    -e "OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g" \
    -e "path.repo=/usr/share/opensearch/snapshots" \
    "$OS_IMAGE" >/dev/null
  # path.repo: 색인 스냅샷 이관(62/63-*-index.sh)의 리포지토리 경로 — 기동 시점에만 설정 가능
fi

# ---------- 2. 헬스 대기 ----------
wait_for_http "http://localhost:$PORT_OPENSEARCH/_cluster/health" "OpenSearch" 120

fi  # INFRA_MODE 분기 끝

# ---------- 3. Ollama ----------
if ! port_listening "$PORT_OLLAMA"; then
  log "Ollama 서비스 시작"
  if [ "$OS" = "Darwin" ]; then
    brew services start ollama >/dev/null
  else
    sudo systemctl start ollama 2>/dev/null || { nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 & }
  fi
  wait_for_http "http://localhost:$PORT_OLLAMA/api/tags" "Ollama" 60
else
  log "Ollama 이미 실행 중"
fi

# ---------- 4. LLM 모델 확보 (기본 gemma3:4b 약 3.3GB — 최초 1회) ----------
if ollama list | awk '{print $1}' | grep -Fqx "$OLLAMA_MODEL"; then
  log "모델 준비됨: $OLLAMA_MODEL"
else
  log "모델 다운로드 시도: $OLLAMA_MODEL (Ollama 레지스트리)"
  if ! ollama pull "$OLLAMA_MODEL"; then
    warn "Ollama 레지스트리 실패 (사내망 대용량 블롭 차단 추정) → HuggingFace 경유 폴백"
    ollama pull "$OLLAMA_MODEL_HF_FALLBACK" || die "HuggingFace 경유도 실패 — 가이드의 대안 2~4 참고"
    ollama cp "$OLLAMA_MODEL_HF_FALLBACK" "$OLLAMA_MODEL"
    log "별칭 생성 완료: $OLLAMA_MODEL_HF_FALLBACK → $OLLAMA_MODEL"
  fi
fi

log "Phase B 완료 — 다음: ./30-setup-config.sh"
