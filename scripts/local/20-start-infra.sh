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

# ---------- 2. Ollama (systemd — 재부팅 뒤에도 올라오도록 enable) ----------
# keep_alive 는 systemd 드롭인으로 서비스 환경에 준다 — 어느 클라이언트 요청에도 적용되고 재부팅 뒤에도 유지된다.
OLLAMA_DROPIN=/etc/systemd/system/ollama.service.d/override.conf
OLLAMA_DROPIN_WANT="[Service]
Environment=\"OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}\""
if [ -f /etc/systemd/system/ollama.service ] || [ -f /lib/systemd/system/ollama.service ]; then
  if [ "$(sudo cat "$OLLAMA_DROPIN" 2>/dev/null)" != "$OLLAMA_DROPIN_WANT" ]; then
    log "Ollama keep_alive 설정: $OLLAMA_KEEP_ALIVE ($OLLAMA_DROPIN)"
    sudo install -d -m 755 "$(dirname "$OLLAMA_DROPIN")"
    printf '%s\n' "$OLLAMA_DROPIN_WANT" | sudo tee "$OLLAMA_DROPIN" >/dev/null
    sudo systemctl daemon-reload
    if systemctl is-active --quiet ollama; then sudo systemctl restart ollama; fi
  fi
  # ★ start 가 아니라 enable --now — start 만 하면 재부팅(Resume) 뒤 Ollama 만 안 올라와 채팅이 실패한다 (2026-10-16 실측)
  log "Ollama 서비스 기동 (systemd · enable)"
  sudo systemctl enable --now ollama
  wait_for_http "http://localhost:$PORT_OLLAMA/api/tags" "Ollama" 60
elif ! port_listening "$PORT_OLLAMA"; then
  # systemd 유닛이 없는 환경 — 수동 기동 폴백 (재부팅 뒤 자동 기동은 안 된다)
  log "Ollama 수동 기동 (systemd 유닛 없음)"
  OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
  wait_for_http "http://localhost:$PORT_OLLAMA/api/tags" "Ollama" 60
else
  log "Ollama 이미 실행 중 (systemd 유닛 없음)"
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

# ---------- 4. 모델 예열 — VRAM 에 미리 올려 둔다 ----------
# prompt 없이 /api/generate 를 부르면 생성 없이 적재만 한다. 첫 질문에 붙던 적재 시간(실측 32~85초)을 기동 단계로
# 옮기고, 뒤에 돌아갈 대량 임베딩(bge-m3)보다 LLM 이 먼저 자리를 잡아 CPU 로 밀리지 않게 한다.
log "모델 예열: $OLLAMA_MODEL (VRAM 적재 · keep_alive $OLLAMA_KEEP_ALIVE)"
t0=$(date +%s)
if curl -sf --max-time 300 "http://localhost:$PORT_OLLAMA/api/generate" \
     -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":\"$OLLAMA_KEEP_ALIVE\"}" >/dev/null; then
  log "모델 예열 완료 ($(( $(date +%s) - t0 ))초) — $(ollama ps 2>/dev/null | awk 'NR==2')"
else
  warn "모델 예열 실패 — 첫 질문에 적재 시간이 붙는다 (ollama ps · journalctl -u ollama 확인)"
fi

log "Phase B 완료 — 다음: ./30-setup-config.sh"
