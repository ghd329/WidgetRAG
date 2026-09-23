#!/usr/bin/env bash
# ===========================================================
# [이관] LLM 모델 내보내기 — Ollama 모델 디렉토리 아카이브 (선택 단계)
#
#   모델은 타겟에서 재다운로드 가능해 이관 비필수지만, 다음 경우 이 경로를 쓴다:
#     - 타겟 외부망이 느리거나 모델 레지스트리가 차단된 경우 (대역폭 절약)
#     - 계약 원형 검증: 모델을 오브젝트 스토리지 경유로 이전하고 정합성 확인
#       (본선 vLLM 실증은 수십 GB 모델이 진짜 이관 대상 — 여기서 경로를 미리 검증)
#
#   산출물 (60/62와 같은 형식):
#     widgetrag-model-<ts>.tgz         모델 디렉토리 아카이브
#     widgetrag-model-<ts>.tgz.sha256  아카이브 해시
#     widgetrag-model-<ts>.modellist   ollama list 스냅샷 — 타겟(65)이 복원 후 대조
#
#   사용법:
#     ./64-export-model.sh [출력디렉토리]                      # 기본: ./exports
#     OBJECT_STORAGE_URI=s3://bucket/widgetrag ./64-export-model.sh
#
#   ※ Docker Compose(B)의 모델은 ollama-data 볼륨 — widgetrag-volume-migrate.sh 사용.
#   ※ 서비스 중지 불필요 (모델 파일은 pull 완료 후 정적) — 단, 내보내는 동안
#     ollama pull을 실행하지 말 것 (아카이브 정합성).
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

OUT_DIR="${1:-$SCRIPT_DIR/exports}"
TS="$(date +%Y%m%d%H%M%S)"
BASE="widgetrag-model-$TS"
ARCHIVE="$OUT_DIR/$BASE.tgz"
# systemd 설치 기본 경로 (ollama 유저 소유). nohup 폴백으로 띄웠다면 OLLAMA_MODELS_DIR=~/.ollama/models 지정
MODELS_DIR="${OLLAMA_MODELS_DIR:-/usr/share/ollama/.ollama/models}"

sha256() { xargs -r sha256sum; }

# ---------- 0. 사전 점검 ----------
sudo test -d "$MODELS_DIR" || die "모델 디렉토리 없음: $MODELS_DIR (다른 경로면 OLLAMA_MODELS_DIR= 지정)"
mkdir -p "$OUT_DIR"

# ---------- 1. 모델 목록 스냅샷 (타겟 대조용) ----------
if port_listening "$PORT_OLLAMA"; then
  ollama list | tee "$OUT_DIR/$BASE.modellist"
else
  warn "Ollama 미기동 — 모델 목록 스냅샷 생략 (타겟 대조는 $OLLAMA_MODEL 존재 확인으로 대체)"
  echo "# ollama 미기동 상태에서 내보냄 ($TS)" > "$OUT_DIR/$BASE.modellist"
fi

# ---------- 2. 아카이브 + 해시 ----------
log "모델 아카이브 생성: $ARCHIVE ($(sudo du -sh "$MODELS_DIR" | cut -f1))"
sudo tar -czf "$ARCHIVE" -C "$(dirname "$MODELS_DIR")" "$(basename "$MODELS_DIR")"
sudo chown "$USER" "$ARCHIVE"
( cd "$OUT_DIR" && echo "$BASE.tgz" | sha256 ) > "$ARCHIVE.sha256"

log "내보내기 완료"
echo "  아카이브     : $ARCHIVE"
echo "  아카이브 해시: $(awk '{print $1}' "$ARCHIVE.sha256")"
echo "  모델 목록    : $OUT_DIR/$BASE.modellist"

# ---------- 3. 오브젝트 스토리지 업로드 (선택) ----------
if [ -n "${OBJECT_STORAGE_URI:-}" ]; then
  command -v aws >/dev/null 2>&1 || die "aws CLI 필요 (S3 호환 스토리지는 --endpoint-url 환경 구성)"
  log "오브젝트 스토리지 업로드: $OBJECT_STORAGE_URI/"
  aws s3 cp "$ARCHIVE"                  "$OBJECT_STORAGE_URI/$BASE.tgz"
  aws s3 cp "$ARCHIVE.sha256"           "$OBJECT_STORAGE_URI/$BASE.tgz.sha256"
  aws s3 cp "$OUT_DIR/$BASE.modellist"  "$OBJECT_STORAGE_URI/$BASE.modellist"
  echo
  log "타겟에서 가져오기: ./65-import-model.sh $OBJECT_STORAGE_URI/$BASE.tgz"
else
  echo
  log "업로드 생략 (OBJECT_STORAGE_URI 미지정) — 타겟에서: ./65-import-model.sh <아카이브 경로>"
fi
