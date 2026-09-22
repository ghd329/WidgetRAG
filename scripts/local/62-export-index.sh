#!/usr/bin/env bash
# ===========================================================
# [이관] 색인 내보내기 — OpenSearch 스냅샷 (방법③: 무중지·증분)
#
#   방법①(데이터 디렉토리 복사)과 달리 OpenSearch를 중지하지 않고 뜬다.
#   같은 리포지토리에 반복 실행하면 스냅샷이 **증분**으로 쌓인다(변경 세그먼트만) —
#   컷오버 시 "사전 1차 스냅샷 복원 → 당일 쓰기중단 → 2차 스냅샷(변경분) 전송·복원"으로
#   중단 시간이 전체 색인 크기에 묶이지 않는다.
#   (LexAI 병행 검증 2026-09-22에서 이식 — 253k건/6.0GB 규모에서 생성 2.9분 실측)
#
#   산출물 (60-export-data.sh와 같은 형식):
#     widgetrag-index-<ts>.tgz         리포지토리 아카이브 (모든 스냅샷 = 증분 이력 포함)
#     widgetrag-index-<ts>.tgz.sha256  아카이브 해시
#     widgetrag-index-<ts>.doccount    인덱스별 문서 수 — 타겟(63)이 복원 후 대조
#
#   사용법:
#     ./62-export-index.sh [출력디렉토리]                      # 기본: ./exports
#     OBJECT_STORAGE_URI=s3://bucket/widgetrag ./62-export-index.sh
#
#   선행 조건: OpenSearch에 path.repo 설정 — native 모드는 이 스크립트가 최초 1회
#   자동 구성(opensearch.yml 등록 + 재시작), container 모드는 20-start-infra.sh가
#   생성한 컨테이너에 이미 설정돼 있다(구버전 컨테이너는 재생성 필요 — 실패 시 안내).
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

OUT_DIR="${1:-$SCRIPT_DIR/exports}"
TS="$(date +%Y%m%d%H%M%S)"
BASE="widgetrag-index-$TS"
OS_URL="http://localhost:$PORT_OPENSEARCH"
REPO_NAME="widgetrag"
SNAPSHOT="snap-$TS"
if [ "$INFRA_MODE" = "native" ]; then
  REPO_LOC="/var/lib/opensearch/snapshots"     # 호스트 경로 (opensearch 소유)
else
  REPO_LOC="/usr/share/opensearch/snapshots"   # 컨테이너 내부 경로
fi

sha256() {  # 파일 목록을 stdin으로 받아 "해시  경로" 출력 (Linux/macOS 겸용)
  if command -v sha256sum >/dev/null 2>&1; then xargs -r sha256sum
  else xargs shasum -a 256; fi
}

# ---------- 0. 사전 점검 (무중지 — 서비스는 떠 있어야 한다) ----------
curl -fsS --max-time 5 "$OS_URL/_cluster/health" >/dev/null \
  || die "OpenSearch 미기동 — ./20-start-infra.sh 먼저 (스냅샷은 서비스 무중지로 뜬다)"

# ---------- 1. 스냅샷 리포지토리 준비 (멱등) ----------
register_repo() {
  curl -fsS -X PUT "$OS_URL/_snapshot/$REPO_NAME" -H 'Content-Type: application/json' \
    -d "{\"type\":\"fs\",\"settings\":{\"location\":\"$REPO_LOC\"}}" >/dev/null 2>&1
}
if ! register_repo; then
  if [ "$INFRA_MODE" = "native" ]; then
    log "path.repo 미구성 — opensearch.yml 등록 + 재시작 (최초 1회)"
    grep -q '^path.repo' /etc/opensearch/opensearch.yml 2>/dev/null \
      || echo "path.repo: [\"$REPO_LOC\"]" | sudo tee -a /etc/opensearch/opensearch.yml >/dev/null
    sudo install -d -o opensearch -g opensearch "$REPO_LOC"
    sudo systemctl restart opensearch
    wait_for_http "$OS_URL/_cluster/health" "OpenSearch" 120
    register_repo || die "리포지토리 등록 실패 — /etc/opensearch/opensearch.yml 의 path.repo 확인"
  else
    die "리포지토리 등록 실패 — 컨테이너에 path.repo 미설정 (구버전 컨테이너).
  재생성: docker rm -f $OS_CONTAINER && ./20-start-infra.sh
  (⚠️ 색인이 함께 삭제되므로 CSV 재업로드 또는 63-import-index.sh 재복원 필요)"
  fi
fi
log "스냅샷 리포지토리 준비 완료: $REPO_NAME → $REPO_LOC"

# ---------- 2. 스냅샷 생성 (무중지 · 반복 실행 시 증분) ----------
log "스냅샷 생성: $SNAPSHOT (시스템 인덱스 제외)"
RESP="$(curl -fsS -X PUT "$OS_URL/_snapshot/$REPO_NAME/$SNAPSHOT?wait_for_completion=true" \
  -H 'Content-Type: application/json' -d '{"indices":"*,-.*"}')" || die "스냅샷 생성 실패"
echo "$RESP" | grep -q '"state":"SUCCESS"' || die "스냅샷 상태가 SUCCESS가 아님: $RESP"
log "스냅샷 완료: $SNAPSHOT"

# ---------- 3. 문서 수 기준선 (타겟 대조용) ----------
mkdir -p "$OUT_DIR"
DOCCOUNT="$OUT_DIR/$BASE.doccount"
curl -fsS "$OS_URL/_cat/indices?h=index,docs.count" | grep -v '^\.' | LC_ALL=C sort > "$DOCCOUNT"
log "문서 수 기준선: $DOCCOUNT ($(wc -l < "$DOCCOUNT" | tr -d ' ')개 인덱스)"

# ---------- 4. 리포지토리 아카이브 + 해시 ----------
ARCHIVE="$OUT_DIR/$BASE.tgz"
log "리포지토리 아카이브 생성: $ARCHIVE (누적 스냅샷 전체 포함)"
if [ "$INFRA_MODE" = "native" ]; then
  sudo tar -czf "$ARCHIVE" -C "$REPO_LOC" .
  sudo chown "$USER" "$ARCHIVE"
else
  docker exec "$OS_CONTAINER" tar -czf /tmp/os-snap.tgz -C "$REPO_LOC" .
  docker cp "$OS_CONTAINER:/tmp/os-snap.tgz" "$ARCHIVE" >/dev/null
  docker exec "$OS_CONTAINER" rm -f /tmp/os-snap.tgz
fi
( cd "$OUT_DIR" && echo "$BASE.tgz" | sha256 ) > "$ARCHIVE.sha256"

log "내보내기 완료"
echo "  아카이브     : $ARCHIVE"
echo "  아카이브 해시: $(awk '{print $1}' "$ARCHIVE.sha256")"
echo "  문서 수 기준 : $DOCCOUNT"

# ---------- 5. 오브젝트 스토리지 업로드 (선택) ----------
if [ -n "${OBJECT_STORAGE_URI:-}" ]; then
  command -v aws >/dev/null 2>&1 || die "aws CLI 필요 (S3 호환 스토리지는 --endpoint-url 환경 구성)"
  log "오브젝트 스토리지 업로드: $OBJECT_STORAGE_URI/"
  aws s3 cp "$ARCHIVE"        "$OBJECT_STORAGE_URI/$BASE.tgz"
  aws s3 cp "$ARCHIVE.sha256" "$OBJECT_STORAGE_URI/$BASE.tgz.sha256"
  aws s3 cp "$DOCCOUNT"       "$OBJECT_STORAGE_URI/$BASE.doccount"
  echo
  log "타겟에서 가져오기: ./63-import-index.sh $OBJECT_STORAGE_URI/$BASE.tgz"
else
  echo
  log "업로드 생략 (OBJECT_STORAGE_URI 미지정) — 타겟에서: ./63-import-index.sh <아카이브 경로>"
fi

# 증분 컷오버 안내
echo
log "증분 컷오버: 사전에 이 아카이브를 타겟에 복원해 예열 → 당일 소스 쓰기중단 후 이 스크립트를
    재실행하면 새 스냅샷은 변경분만 담긴다 — 새 아카이브를 전송해 63으로 최신 스냅샷을 복원"
