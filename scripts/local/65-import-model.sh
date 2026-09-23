#!/usr/bin/env bash
# ===========================================================
# [이관] LLM 모델 가져오기 — 64-export-model.sh 산출물을 타겟에 복원 + 경로 재연결 확인
#
#     1) 아카이브를 받아(로컬 경로 또는 s3://) 아카이브 해시 검증
#     2) Ollama 중지 → 모델 디렉토리 복원 + 소유자 정정 → 재기동 (경로 재연결)
#     3) ollama list 로 모델 인식 확인 — 기본 모델($OLLAMA_MODEL) 존재를 자동 판정,
#        소스 목록(.modellist)이 있으면 대조 출력
#
#   사용법:
#     ./65-import-model.sh /path/to/widgetrag-model-<ts>.tgz
#     ./65-import-model.sh s3://bucket/widgetrag/widgetrag-model-<ts>.tgz
#
#   복원 후 20-start-infra.sh 의 모델 확보 단계는 "이미 있음"으로 건너뛰게 된다 —
#   재다운로드 없이 기동하는 것이 이 경로의 목적.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SRC="${1:-}"
[ -n "$SRC" ] || die "사용법: $0 <widgetrag-model-*.tgz 경로 또는 s3://...>"
MODELS_DIR="${OLLAMA_MODELS_DIR:-/usr/share/ollama/.ollama/models}"
OLLAMA_HOME="$(dirname "$MODELS_DIR")"

sha256_check() { sha256sum -c "$1" --quiet; }

# ---------- 1. 아카이브 확보 ----------
WORK="$SCRIPT_DIR/imports"
mkdir -p "$WORK"
case "$SRC" in
  s3://*)
    command -v aws >/dev/null 2>&1 || die "aws CLI 필요"
    BASE="$(basename "$SRC" .tgz)"
    log "오브젝트 스토리지에서 다운로드: $SRC ($(basename "$SRC"))"
    aws s3 cp "$SRC"                  "$WORK/$BASE.tgz"
    aws s3 cp "$SRC.sha256"           "$WORK/$BASE.tgz.sha256"
    aws s3 cp "${SRC%.tgz}.modellist" "$WORK/$BASE.modellist" || true
    ARCHIVE="$WORK/$BASE.tgz"
    ;;
  *)
    ARCHIVE="$SRC"
    BASE="$(basename "$SRC" .tgz)"
    ;;
esac
[ -f "$ARCHIVE" ] || die "아카이브 없음: $ARCHIVE"

# ---------- 2. 아카이브 해시 검증 ----------
if [ -f "$ARCHIVE.sha256" ]; then
  log "아카이브 해시 검증"
  ( cd "$(dirname "$ARCHIVE")" && sha256_check "$(basename "$ARCHIVE").sha256" ) || die "아카이브 해시 불일치 — 전송 중 손상"
  log "아카이브 해시 일치"
else
  warn "아카이브 해시 파일 없음 — 복원 후 모델 인식 확인으로만 검증"
fi

# ---------- 3. 복원 (Ollama 중지 → 풀기 → 소유자 정정 → 재기동) ----------
log "Ollama 중지 후 모델 디렉토리 복원: $MODELS_DIR"
sudo systemctl stop ollama 2>/dev/null || true
sudo mkdir -p "$OLLAMA_HOME"
sudo tar -xzf "$ARCHIVE" -C "$OLLAMA_HOME"
# systemd 설치의 ollama는 전용 유저로 돌므로 소유자를 맞춰야 인식된다 (유저 없으면 현재 유저 유지)
id ollama >/dev/null 2>&1 && sudo chown -R ollama:ollama "$OLLAMA_HOME"
sudo systemctl start ollama 2>/dev/null || { nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 & }
wait_for_http "http://localhost:$PORT_OLLAMA/api/tags" "Ollama" 60

# ---------- 4. 모델 인식 확인 (경로 재연결 판정) ----------
echo
log "복원 후 모델 목록:"
ollama list
if ollama list | awk '{print $1}' | grep -Fqx "$OLLAMA_MODEL"; then
  log "모델 인식 확인: $OLLAMA_MODEL — 재다운로드 없이 사용 가능"
else
  die "기본 모델($OLLAMA_MODEL)이 목록에 없음 — 아카이브 내용/OLLAMA_MODELS_DIR 경로 확인"
fi
MODELLIST="$(dirname "$ARCHIVE")/$BASE.modellist"
if [ -f "$MODELLIST" ]; then
  echo
  log "소스 목록과 대조 (좌: 소스 / 우: 타겟 — 정보용)"
  diff "$MODELLIST" <(ollama list) || true
fi

echo
log "복원 완료 — 다음: ./40-start-apps.sh 또는 ./start.sh"
