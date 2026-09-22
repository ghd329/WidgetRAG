#!/usr/bin/env bash
# ===========================================================
# [이관] 데이터 내보내기 — SQLite DB + 업로드 파일 (오브젝트 스토리지 경유용)
#
#   계약 요구(수행계획서 3-3): 모델·데이터를 오브젝트 스토리지 경유로 이전하고
#   "용량·파일/오브젝트 개수·해시" 정합성을 확인한다. 이 스크립트는 그 소스 측:
#     1) SQLite WAL 체크포인트로 DB를 단일 파일 상태로 만들고 (해시가 결정적이 되는 전제)
#     2) 파일별 SHA-256 매니페스트 + 요약(개수·총 바이트)을 만들고
#     3) 아카이브(.tgz)와 아카이브 해시를 산출한다
#     4) OBJECT_STORAGE_URI(s3://버킷/prefix)가 있으면 업로드까지 수행
#
#   사용법:
#     ./60-export-data.sh [출력디렉토리]                       # 기본: ./exports
#     OBJECT_STORAGE_URI=s3://bucket/widgetrag ./60-export-data.sh
#
#   ⚠️ 백엔드가 실행 중이면 중단한다 — 실행 중 복사는 WAL 미체크포인트 트랜잭션이
#      누락될 수 있고, 해시도 복사 시점마다 달라져 정합성 검증이 성립하지 않는다.
#      (종료: ./90-stop-all.sh 또는 sudo systemctl stop widgetrag-backend)
#
#   ※ OpenSearch 색인은 범위 밖 — 리허설 절차서의 방법①(데이터 디렉토리 복사) 또는
#     방법②(타겟에서 CSV 재업로드 재색인)를 따른다.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

OUT_DIR="${1:-$SCRIPT_DIR/exports}"
TS="$(date +%Y%m%d%H%M%S)"
BASE="widgetrag-data-$TS"
ARCHIVE="$OUT_DIR/$BASE.tgz"
MANIFEST="$OUT_DIR/$BASE.manifest"

sha256() {  # 파일 목록을 stdin으로 받아 "해시  경로" 출력 (Linux/macOS 겸용)
  if command -v sha256sum >/dev/null 2>&1; then xargs -r sha256sum
  else xargs shasum -a 256; fi
}

# ---------- 0. 사전 점검 ----------
[ -d "$STORAGE_DIR" ] || die "데이터 디렉토리 없음: $STORAGE_DIR"
[ -f "$SQLITE_DB_FILE" ] || warn "SQLite DB 파일 없음 ($SQLITE_DB_FILE) — 업로드 파일만 내보냄"
port_listening "$PORT_BACKEND" && die "백엔드(:$PORT_BACKEND)가 실행 중 — 정합성 있는 내보내기를 위해 먼저 중지하세요"

mkdir -p "$OUT_DIR"

# ---------- 1. SQLite WAL 체크포인트 (단일 파일화) ----------
if [ -f "$SQLITE_DB_FILE" ]; then
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI 필요 — sudo apt install sqlite3 (macOS는 기본 내장)"
  log "SQLite WAL 체크포인트 (미반영 트랜잭션을 본 파일로 병합)"
  sqlite3 "$SQLITE_DB_FILE" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  RESULT="$(sqlite3 "$SQLITE_DB_FILE" "PRAGMA integrity_check;")"
  [ "$RESULT" = "ok" ] || die "SQLite 무결성 검사 실패: $RESULT"
  log "SQLite 무결성 검사 통과 (integrity_check=ok)"
  # 체크포인트 후에도 -wal이 남아 있으면(다른 접속 잔존 등) 정합성 보장이 깨진다
  if [ -s "$SQLITE_DB_FILE-wal" ]; then
    die "WAL 파일이 비어 있지 않음 ($SQLITE_DB_FILE-wal) — DB에 접속 중인 프로세스 확인"
  fi
fi

# ---------- 2. 매니페스트 (파일별 SHA-256 + 개수·총 바이트) ----------
log "매니페스트 생성: $MANIFEST"
# -shm/-wal은 런타임 부산물이라 이관 대상에서 제외 (체크포인트 후엔 없거나 빈 파일)
( cd "$STORAGE_DIR" && find . -type f ! -name '*.db-wal' ! -name '*.db-shm' | LC_ALL=C sort | sha256 ) > "$MANIFEST"
FILE_COUNT="$(wc -l < "$MANIFEST" | tr -d ' ')"
TOTAL_BYTES="$(cd "$STORAGE_DIR" && find . -type f ! -name '*.db-wal' ! -name '*.db-shm' -print0 | xargs -0 stat -f%z 2>/dev/null | awk '{s+=$1} END{print s}' || true)"
[ -n "$TOTAL_BYTES" ] || TOTAL_BYTES="$(cd "$STORAGE_DIR" && find . -type f ! -name '*.db-wal' ! -name '*.db-shm' -print0 | xargs -0 stat -c%s | awk '{s+=$1} END{print s}')"
{
  echo "# 요약: 파일 $FILE_COUNT 개, 총 $TOTAL_BYTES 바이트, 생성 $TS"
  echo "# 검증: 타겟에서 ./61-import-data.sh 가 이 매니페스트로 개수·용량·해시를 대조한다"
} >> "$MANIFEST"

# ---------- 3. 아카이브 + 아카이브 해시 ----------
log "아카이브 생성: $ARCHIVE"
tar -czf "$ARCHIVE" -C "$STORAGE_DIR" --exclude='*.db-wal' --exclude='*.db-shm' .
( cd "$OUT_DIR" && echo "$BASE.tgz" | sha256 ) > "$ARCHIVE.sha256"

log "내보내기 완료 — 파일 $FILE_COUNT 개 / $TOTAL_BYTES 바이트"
echo "  아카이브   : $ARCHIVE"
echo "  매니페스트 : $MANIFEST"
echo "  아카이브 해시: $(awk '{print $1}' "$ARCHIVE.sha256")"

# ---------- 4. 오브젝트 스토리지 업로드 (선택) ----------
if [ -n "${OBJECT_STORAGE_URI:-}" ]; then
  command -v aws >/dev/null 2>&1 || die "aws CLI 필요 (S3 호환 스토리지는 --endpoint-url 환경 구성)"
  log "오브젝트 스토리지 업로드: $OBJECT_STORAGE_URI/"
  aws s3 cp "$ARCHIVE"        "$OBJECT_STORAGE_URI/$BASE.tgz"
  aws s3 cp "$ARCHIVE.sha256" "$OBJECT_STORAGE_URI/$BASE.tgz.sha256"
  aws s3 cp "$MANIFEST"       "$OBJECT_STORAGE_URI/$BASE.manifest"
  echo
  log "타겟에서 가져오기: ./61-import-data.sh $OBJECT_STORAGE_URI/$BASE.tgz"
else
  echo
  log "업로드 생략 (OBJECT_STORAGE_URI 미지정) — 타겟에서: ./61-import-data.sh <아카이브 경로>"
fi
