#!/usr/bin/env bash
# ===========================================================
# [이관] 색인 가져오기 — 62-export-index.sh 산출물(스냅샷 리포지토리)을 타겟에 복원
#
#     1) 아카이브를 받아(로컬 경로 또는 s3://) 아카이브 해시 검증
#     2) 스냅샷 리포지토리 배치 + 등록
#     3) 스냅샷 복원 (기본: 리포지토리의 최신 스냅샷 — 증분 컷오버 시 2차 스냅샷이 이것)
#     4) 인덱스별 문서 수를 소스 기준선(.doccount)과 대조 → 자동판정
#
#   사용법:
#     ./63-import-index.sh /path/to/widgetrag-index-<ts>.tgz [스냅샷명]
#     ./63-import-index.sh s3://bucket/widgetrag/widgetrag-index-<ts>.tgz
#   (같은 위치에 <이름>.tgz.sha256 과 <이름>.doccount 가 있어야 한다 — 62가 함께 산출)
#
#   ⚠️ 복원은 타겟의 동명 인덱스를 삭제하고 진행한다 (이관 목적상 타겟 색인은 대체 대상).
#      복원을 앱 첫 기동 전에 수행하면 삭제할 것도 없다 — 그 순서를 권장.
#   OpenSearch 버전 고정(2.18.0) 원칙은 스냅샷 방식에도 동일하게 적용된다.
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

SRC="${1:-}"
[ -n "$SRC" ] || die "사용법: $0 <widgetrag-index-*.tgz 경로 또는 s3://...> [스냅샷명]"
OS_URL="http://localhost:$PORT_OPENSEARCH"
REPO_NAME="widgetrag"
if [ "$INFRA_MODE" = "native" ]; then
  REPO_LOC="/var/lib/opensearch/snapshots"
else
  REPO_LOC="/usr/share/opensearch/snapshots"
fi

sha256_check() {  # $1=해시 파일 (현재 디렉토리 기준 검증)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1" --quiet
  else shasum -a 256 -c "$1" --quiet; fi
}
os_json() {  # $1=경로 $2=python 표현식 — OpenSearch 응답 JSON에서 값 추출
  curl -fsS "$OS_URL$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)"
}

curl -fsS --max-time 5 "$OS_URL/_cluster/health" >/dev/null \
  || die "OpenSearch 미기동 — ./20-start-infra.sh 먼저"

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
    aws s3 cp "${SRC%.tgz}.doccount" "$WORK/$BASE.doccount"
    ARCHIVE="$WORK/$BASE.tgz"
    ;;
  *)
    ARCHIVE="$SRC"
    BASE="$(basename "$SRC" .tgz)"
    ;;
esac
[ -f "$ARCHIVE" ] || die "아카이브 없음: $ARCHIVE"
DOCCOUNT="$(dirname "$ARCHIVE")/$BASE.doccount"
[ -f "$DOCCOUNT" ] || die "문서 수 기준선 없음: $DOCCOUNT (62-export-index.sh 가 함께 산출한 파일 필요)"

# ---------- 2. 아카이브 해시 검증 ----------
if [ -f "$ARCHIVE.sha256" ]; then
  log "아카이브 해시 검증"
  ( cd "$(dirname "$ARCHIVE")" && sha256_check "$(basename "$ARCHIVE").sha256" ) || die "아카이브 해시 불일치 — 전송 중 손상"
  log "아카이브 해시 일치"
else
  warn "아카이브 해시 파일 없음 — 복원 후 문서 수 대조로만 확인"
fi

# ---------- 3. 리포지토리 배치 + 등록 ----------
log "스냅샷 리포지토리 배치: $REPO_LOC"
if [ "$INFRA_MODE" = "native" ]; then
  grep -q '^path.repo' /etc/opensearch/opensearch.yml 2>/dev/null || {
    log "path.repo 미구성 — opensearch.yml 등록 + 재시작 (최초 1회)"
    echo "path.repo: [\"$REPO_LOC\"]" | sudo tee -a /etc/opensearch/opensearch.yml >/dev/null
    NEED_RESTART=1
  }
  sudo install -d -o opensearch -g opensearch "$REPO_LOC"
  sudo tar -xzf "$ARCHIVE" -C "$REPO_LOC"
  sudo chown -R opensearch:opensearch "$REPO_LOC"
  if [ -n "${NEED_RESTART:-}" ]; then
    sudo systemctl restart opensearch
    wait_for_http "$OS_URL/_cluster/health" "OpenSearch" 120
  fi
else
  docker cp "$ARCHIVE" "$OS_CONTAINER:/tmp/os-snap.tgz" >/dev/null
  docker exec -u 0 "$OS_CONTAINER" sh -c \
    "mkdir -p $REPO_LOC && tar -xzf /tmp/os-snap.tgz -C $REPO_LOC && chown -R 1000:1000 $REPO_LOC && rm -f /tmp/os-snap.tgz"
fi
curl -fsS -X PUT "$OS_URL/_snapshot/$REPO_NAME" -H 'Content-Type: application/json' \
  -d "{\"type\":\"fs\",\"settings\":{\"location\":\"$REPO_LOC\"}}" >/dev/null \
  || die "리포지토리 등록 실패 — path.repo 설정 확인 (container 모드는 20-start-infra.sh 로 컨테이너 재생성)"

# ---------- 4. 스냅샷 선택 (기본: 최신 = 증분 컷오버의 2차 스냅샷) ----------
SNAPSHOT="${2:-}"
if [ -z "$SNAPSHOT" ]; then
  SNAPSHOT="$(os_json "/_snapshot/$REPO_NAME/_all" \
    "sorted(d['snapshots'], key=lambda s: s['start_time_in_millis'])[-1]['snapshot']")" \
    || die "리포지토리에 스냅샷 없음"
fi
log "복원할 스냅샷: $SNAPSHOT"

# ---------- 5. 동명 인덱스 정리 후 복원 ----------
INDICES="$(os_json "/_snapshot/$REPO_NAME/$SNAPSHOT" "'\n'.join(d['snapshots'][0]['indices'])")"
for idx in $INDICES; do
  if curl -fsS -o /dev/null "$OS_URL/$idx" 2>/dev/null; then
    warn "기존 인덱스 삭제 (스냅샷으로 대체): $idx"
    curl -fsS -X DELETE "$OS_URL/$idx" >/dev/null
  fi
done
log "복원 실행 (wait_for_completion)"
curl -fsS -X POST "$OS_URL/_snapshot/$REPO_NAME/$SNAPSHOT/_restore?wait_for_completion=true" >/dev/null \
  || die "복원 실패 — _snapshot/$REPO_NAME/$SNAPSHOT/_status 확인"

# ---------- 6. 문서 수 대조 (소스 기준선과) ----------
ACTUAL="$WORK/$BASE.doccount.actual"
curl -fsS "$OS_URL/_cat/indices?h=index,docs.count" | grep -v '^\.' | LC_ALL=C sort > "$ACTUAL"
echo
log "색인 이관 정합성 검증 (인덱스별 문서 수)"
if diff "$DOCCOUNT" "$ACTUAL"; then
  log "문서 수 전체 일치 — 소스 기준선과 동일 ($(wc -l < "$ACTUAL" | tr -d ' ')개 인덱스)"
else
  die "문서 수 불일치 — 위 diff 확인 (좌: 소스 / 우: 타겟)"
fi

echo
log "복원 완료 — 다음: ./40-start-apps.sh 또는 CLIENT_CODE=... ./50-verify.sh"
