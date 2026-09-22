#!/usr/bin/env bash
# ===========================================================
# [Phase B] 인프라 기동 — OpenSearch, Ollama + LLM 모델
#
#   - 관계형 DB는 SQLite 임베디드라 기동할 서버가 없다 (백엔드가 파일로 직접 접근)
#   - 모델 pull 실패(사내망 차단) 시 HuggingFace 경유로 자동 폴백
#   - 여러 번 실행해도 안전(멱등)
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ---------- 1. OpenSearch (systemd) ----------
log "OpenSearch 기동 (systemd)"
sudo systemctl enable --now opensearch

wait_for_http "http://localhost:$PORT_OPENSEARCH/_cluster/health" "OpenSearch" 120

# ---------- 2. Ollama ----------
if ! port_listening "$PORT_OLLAMA"; then
  log "Ollama 서비스 시작"
  sudo systemctl start ollama 2>/dev/null || { nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 & }
  wait_for_http "http://localhost:$PORT_OLLAMA/api/tags" "Ollama" 60
else
  log "Ollama 이미 실행 중"
fi

# ---------- 3. LLM 모델 확보 (기본 gemma3:4b 약 3.3GB — 최초 1회) ----------
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
