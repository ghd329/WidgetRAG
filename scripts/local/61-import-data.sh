#!/usr/bin/env bash
# ===========================================================
# [이관] 데이터 가져오기 — 60-export-data.sh 산출물을 타겟에 복원 + 정합성 검증
#
#   계약 요구(수행계획서 3-3)의 타겟 측: 이관 전후 "용량·파일/오브젝트 개수·해시"
#   일치 여부를 확인한다.
#     1) 아카이브를 받아(로컬 경로 또는 s3://) 아카이브 해시 검증
#     2) $STORAGE_DIR 에 복원 (기존 디렉토리는 타임스탬프 백업)
#     3) 매니페스트로 파일별 SHA-256 + 개수·총 바이트 대조 → 결과 출력
#
#   사용법:
#     ./61-import-data.sh /path/to/widgetrag-data-<ts>.tgz
#     ./61-import-data.sh s3://bucket/widgetrag/widgetrag-data-<ts>.tgz
#   (같은 위치에 <이름>.tgz.sha256 과 <이름>.manifest 가 있어야 한다 — 60이 함께 산출)
#
#   복원 후 백엔드를 기동하면(./40-start-apps.sh) 이관된 DB로 서비스가 뜬다.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SRC="${1:-}"
[ -n "$SRC" ] || die "사용법: $0 <widgetrag-data-*.tgz 경로 또는 s3://...>"
port_listening "$PORT_BACKEND" && die "백엔드(:$PORT_BACKEND)가 실행 중 — 복원 전에 중지하세요"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then xargs -r sha256sum
  else xargs shasum -a 256; fi
}
sha256_check() {  # $1=매니페스트/해시 파일 (현재 디렉토리 기준 검증)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1" --quiet
  else shasum -a 256 -c "$1" --quiet; fi
}

# ---------- 1. 아카이브 확보 ----------
WORK="$SCRIPT_DIR/imports"
mkdir -p "$WORK"
case "$SRC" in
  s3://*)
    command -v aws >/dev/null 2>&1 || die "aws CLI 필요"
    BASE="$(basename "$SRC" .tgz)"
    log "오브젝트 스토리지에서 다운로드: $SRC"
    aws s3 cp "$SRC"                 "$WORK/$BASE.tgz"
    aws s3 cp "$SRC.sha256"          "$WORK/$BASE.tgz.sha256"
    aws s3 cp "${SRC%.tgz}.manifest" "$WORK/$BASE.manifest"
    ARCHIVE="$WORK/$BASE.tgz"
    ;;
  *)
    ARCHIVE="$SRC"
    BASE="$(basename "$SRC" .tgz)"
    ;;
esac
[ -f "$ARCHIVE" ] || die "아카이브 없음: $ARCHIVE"
MANIFEST="$(dirname "$ARCHIVE")/$BASE.manifest"
[ -f "$MANIFEST" ] || die "매니페스트 없음: $MANIFEST (60-export-data.sh 가 함께 산출한 파일 필요)"

# ---------- 2. 아카이브 해시 검증 ----------
if [ -f "$ARCHIVE.sha256" ]; then
  log "아카이브 해시 검증"
  ( cd "$(dirname "$ARCHIVE")" && sha256_check "$(basename "$ARCHIVE").sha256" ) || die "아카이브 해시 불일치 — 전송 중 손상"
  log "아카이브 해시 일치"
else
  warn "아카이브 해시 파일 없음 — 파일별 매니페스트 검증으로만 확인"
fi

# ---------- 3. 복원 (기존 데이터는 백업) ----------
if [ -d "$STORAGE_DIR" ] && [ -n "$(ls -A "$STORAGE_DIR" 2>/dev/null)" ]; then
  BAK="$STORAGE_DIR.bak.$(date +%Y%m%d%H%M%S)"
  warn "기존 데이터 백업: $STORAGE_DIR → $BAK"
  mv "$STORAGE_DIR" "$BAK"
fi
mkdir -p "$STORAGE_DIR"
log "복원: $ARCHIVE → $STORAGE_DIR"
tar -xzf "$ARCHIVE" -C "$STORAGE_DIR"

# ---------- 4. 정합성 검증 (개수 · 용량 · 해시) ----------
log "파일별 해시 대조 (매니페스트 기준)"
( cd "$STORAGE_DIR" && grep -v '^#' "$MANIFEST" | \
  { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c - --quiet; else shasum -a 256 -c - --quiet; fi; } ) \
  || die "해시 불일치 파일 있음 — 이관 정합성 실패"

EXPECTED_COUNT="$(grep -vc '^#' "$MANIFEST")"
ACTUAL_COUNT="$(cd "$STORAGE_DIR" && find . -type f | wc -l | tr -d ' ')"
ACTUAL_BYTES="$(cd "$STORAGE_DIR" && find . -type f -print0 | xargs -0 stat -f%z 2>/dev/null | awk '{s+=$1} END{print s}' || true)"
[ -n "$ACTUAL_BYTES" ] || ACTUAL_BYTES="$(cd "$STORAGE_DIR" && find . -type f -print0 | xargs -0 stat -c%s | awk '{s+=$1} END{print s}')"

echo
log "이관 정합성 검증 결과"
echo "  해시      : 전체 일치 (SHA-256, $EXPECTED_COUNT 개 파일)"
echo "  파일 개수 : 기대 $EXPECTED_COUNT / 실제 $ACTUAL_COUNT $([ "$EXPECTED_COUNT" = "$ACTUAL_COUNT" ] && echo '— 일치' || echo '— ⚠️ 불일치')"
echo "  총 용량   : $ACTUAL_BYTES 바이트 (매니페스트 요약과 대조: grep '^# 요약' $MANIFEST)"
grep '^# 요약' "$MANIFEST" | sed 's/^/  /'
[ "$EXPECTED_COUNT" = "$ACTUAL_COUNT" ] || die "파일 개수 불일치"

echo
log "복원 완료 — 다음: ./40-start-apps.sh (이관된 DB로 기동)"
