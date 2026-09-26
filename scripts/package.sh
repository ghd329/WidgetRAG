#!/usr/bin/env bash
# ===========================================================
# WidgetRAG 이관 패키지 — 두 실행 형태(Shell 설치형 · Docker Compose) 공용
#
#   소스에서 상태 데이터(색인 · DB · 업로드 파일)를 패키지 하나로 뜨고, 타겟에서 그대로
#   복원한다. 패키지 형식은 실행 형태와 무관하다 — Shell 설치형에서 뜬 패키지를 Compose 에,
#   Compose 에서 뜬 패키지를 Shell 설치형에 복원할 수 있다 (LexAI 이관 패키지와 같은 구성).
#
#   사용법
#     bash package.sh backup [출력디렉토리]              # 소스 — 기본 ~/widgetrag-backup/<시각>
#       UPLOAD_URI=s3://버킷/widgetrag/<시각> bash package.sh backup   # 만든 뒤 업로드까지
#     bash package.sh fetch <URI> [받을디렉토리]          # 타겟 — s3:// · gs:// · https:// · 로컬 경로
#     bash package.sh restore <패키지디렉토리> [all|index|data]
#
#   보통은 직접 부르지 않는다 — 진입물이 SNAPSHOT_URI 를 받아 fetch → restore 를 대신 호출한다:
#     A: curl -fsSL <raw>/scripts/local/bootstrap.sh | SNAPSHOT_URI=s3://… bash
#     B: curl -fsSL <raw>/scripts/compose/deploy.sh  | SNAPSHOT_URI=s3://… bash
#
#   패키지 구성 (디렉토리 하나 — 그대로 오브젝트 스토리지에 올린다)
#     opensearch-snapshots.tar.gz  스냅샷 저장소 (contents.tsv 포함 — 풀자마자 3종 대조)
#     widgetrag.db                 SQLite — VACUUM INTO 로 뜬 일관된 단일 파일 (-wal/-shm 불필요)
#     uploads.tar.gz               업로드 CSV (contents.tsv 포함)
#     doccount.tsv                 인덱스별 문서 수 — 복원 후 대조
#     package.env                  원본 형태 · 업로드 경로 접두사 등 (복원 시 경로 재작성에 사용)
#     checksums.sha256             위 파일들의 SHA-256 — 전송 직후 대조
#     MANIFEST.txt                 사람이 읽는 요약
#   포함하지 않는 것: LLM·임베딩 모델(타겟에서 다시 받음), 관리자 비밀번호·.env(비밀값)
#
#   실행 형태 (RUNTIME=native|compose — 진입물은 명시해서 부른다)
#     native  — systemd opensearch · ~/widgetrag-data (STORAGE_DIR)
#     compose — ~/widgetrag-deploy (COMPOSE_DIR) 의 compose 프로젝트 · 볼륨 upload-data
#
#   기타 환경변수 (전부 선택)
#     FORCE_RESTORE=1    타겟에 DB · 색인이 이미 있어도 덮어쓴다 (기본은 건너뜀 — 재실행 안전)
#     S3_ENDPOINT_URL    S3 호환 스토리지 주소 (예: NCP https://kr.object.ncloudstorage.com)
#     KEEP_SNAPSHOTS     소스 저장소에 남길 스냅샷 수 (기본 2 — 증분의 기준점)
#     ARCHIVE_COMPRESS   none 이면 압축하지 않음 (스냅샷은 이미 압축돼 압축률이 낮다)
# ===========================================================
set -euo pipefail

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춘다.
export DEBIAN_FRONTEND=noninteractive
# snap 으로 설치한 클라우드 CLI 는 /snap/bin 에 있다 (systemd 유닛의 PATH 에는 없다).
PATH="$PATH:/snap/bin"

# TTY 가 아니면(이관 도구가 로그로 수집) 색상 제어문자를 쓰지 않는다.
if [ -t 1 ]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s[package]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[package][WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[package][FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "타겟/소스 VM(Ubuntu Linux) 전용 스크립트입니다"
if [ "$(id -u)" -eq 0 ]; then AS_ROOT=""; else AS_ROOT="sudo"; fi

# ---------- 공통 상수 ----------
MANIFEST_NAME="contents.tsv"
DB_NAME="widgetrag.db"
SNAPSHOT_REPO="widgetrag"          # 소스가 스냅샷을 쌓는 저장소 (반복 실행 시 증분)
IMPORT_REPO="widgetrag-import"     # 타겟이 패키지를 풀어 읽는 저장소 — 소스 저장소와 섞이지 않게 분리
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"
PKG_FILES=(checksums.sha256 package.env doccount.tsv widgetrag.db uploads.tar.gz opensearch-snapshots.tar.gz MANIFEST.txt)
OS="http://127.0.0.1:9200"

# Shell 설치형(A)
STORAGE_DIR="${STORAGE_DIR:-$HOME/widgetrag-data}"
NATIVE_REPO_ROOT="/var/lib/opensearch/snapshots"
NATIVE_OS_YML="/etc/opensearch/opensearch.yml"

# Docker Compose(B)
COMPOSE_DIR="${COMPOSE_DIR:-$HOME/widgetrag-deploy}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$(basename "$COMPOSE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"
COMPOSE_STORAGE_BASE="/data/widgetrag"   # backend 컨테이너 안의 저장 경로 (STORAGE_BASE_PATH)
COMPOSE_REPO_MOUNT="/mnt/snapshots"      # opensearch 컨테이너의 path.repo (docker-compose.yml)
BACKEND_UID=1001                         # backend 이미지의 appuser (backend/Dockerfile)
OPENSEARCH_UID=1000                      # opensearch 이미지의 opensearch 사용자

# ---------- 실행 형태별 경로 ----------
DOCKER=""
docker_cmd() {
  if [ -z "$DOCKER" ]; then
    if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
  fi
  $DOCKER "$@"
}
dc() {
  docker_cmd compose -p "$COMPOSE_PROJECT" --project-directory "$COMPOSE_DIR" \
    -f "$COMPOSE_DIR/docker-compose.yml" -f "$COMPOSE_DIR/docker-compose.images.yml" "$@"
}

setup_runtime() {
  if [ -z "${RUNTIME:-}" ]; then
    if [ -f "$COMPOSE_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 \
       && [ -n "$(dc ps -q opensearch 2>/dev/null)" ]; then
      RUNTIME=compose
    elif systemctl is-active --quiet opensearch 2>/dev/null; then
      RUNTIME=native
    else
      die "실행 형태를 판별하지 못했습니다 — RUNTIME=native 또는 RUNTIME=compose 로 지정하세요"
    fi
  fi
  case "$RUNTIME" in
    native)
      STORAGE_BASE="$STORAGE_DIR"                    # 앱이 기록하는 업로드 경로 (product.storage_path 의 접두사)
      REPO_HOST="$NATIVE_REPO_ROOT"; REPO_LOC="$NATIVE_REPO_ROOT"
      REPO_OWNER="opensearch:opensearch"
      DATA_OWNER="$(id -u):$(id -g)"; DATA_SUDO=""
      ;;
    compose)
      STORAGE_BASE="$COMPOSE_STORAGE_BASE"
      REPO_HOST="$COMPOSE_DIR/snapshots"; REPO_LOC="$COMPOSE_REPO_MOUNT"
      REPO_OWNER="$OPENSEARCH_UID:$OPENSEARCH_UID"
      # 볼륨 마운트 지점(/var/lib/docker/volumes)은 root 만 들어갈 수 있다
      DATA_OWNER="$BACKEND_UID:$BACKEND_UID"; DATA_SUDO="$AS_ROOT"
      ;;
    *) die "RUNTIME 은 native 또는 compose 입니다: $RUNTIME" ;;
  esac
}

data_dir() {  # 호스트에서 본 DB · 업로드 디렉토리
  if [ "$RUNTIME" = compose ]; then
    docker_cmd volume inspect -f '{{ .Mountpoint }}' "${COMPOSE_PROJECT}_upload-data" 2>/dev/null \
      || die "볼륨 ${COMPOSE_PROJECT}_upload-data 가 없습니다 — 먼저: docker compose up --no-start"
  else
    mkdir -p "$STORAGE_DIR"
    echo "$STORAGE_DIR"
  fi
}

backend_running() {
  if [ "$RUNTIME" = compose ]; then
    [ -n "$(dc ps -q --status running backend 2>/dev/null)" ]
  else
    systemctl is-active --quiet widgetrag-backend 2>/dev/null
  fi
}

# ---------- OpenSearch ----------
os_curl() {  # os_curl <curl 인자...> — 실행 형태에 맞는 경로로 OpenSearch 를 호출
  if [ "$RUNTIME" = compose ]; then
    # ★ </dev/null 필수 — docker compose exec 는 -T 여도 stdin 을 읽는다. 파이프로 들어온
    #   호출자(curl | bash)의 남은 본문을 삼켜 조용히 끝나는 문제를 막는다 (LexAI 결함 4).
    dc exec -T opensearch curl -sS "$@" </dev/null
  else
    curl -sS "$@"
  fi
}
py() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

os_ready() {
  local st
  st="$(os_curl "$OS/_cluster/health" 2>/dev/null | py 'd.get("status","")' 2>/dev/null)" || return 1
  [ "$st" = green ] || [ "$st" = yellow ]
}

wait_for() {  # wait_for <설명> <최대초> <명령...>
  local label="$1" timeout="$2" waited=0
  shift 2
  printf '[package] %s 대기' "$label"
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then printf '\n'; return 1; fi
    sleep 3; waited=$((waited + 3)); printf '.'
  done
  printf ' (%ss)\n' "$waited"
}

ensure_repo_path() {  # 스냅샷 저장소 경로를 OpenSearch 가 쓸 수 있게 한다
  if [ "$RUNTIME" = native ]; then
    $AS_ROOT install -d -o opensearch -g opensearch "$NATIVE_REPO_ROOT"
    # ★ sudo grep — opensearch.yml 은 일반 사용자가 못 읽는다. 못 읽은 걸 "없음"으로 보고
    #   다시 덧붙이면 중복 키로 OpenSearch 가 기동 즉시 실패한다 (LexAI 에서 겪은 함정).
    if ! $AS_ROOT grep -q '^path.repo' "$NATIVE_OS_YML" 2>/dev/null; then
      log "   path.repo 등록 — opensearch.yml 에 추가 후 재시작 (최초 1회)"
      echo "path.repo: [\"$NATIVE_REPO_ROOT\"]" | $AS_ROOT tee -a "$NATIVE_OS_YML" >/dev/null
      $AS_ROOT systemctl restart opensearch
    fi
  else
    $AS_ROOT mkdir -p "$REPO_HOST"
    $AS_ROOT chown "$REPO_OWNER" "$REPO_HOST"
  fi
  wait_for "OpenSearch" 180 os_ready || die "OpenSearch 가 준비되지 않았습니다"
}

register_repo() {  # register_repo <이름> <OpenSearch 쪽 경로> [readonly]
  local body out
  body="{\"type\":\"fs\",\"settings\":{\"location\":\"$2\"${3:+,\"readonly\":true}}}"
  out="$(os_curl -X PUT "$OS/_snapshot/$1" -H 'Content-Type: application/json' -d "$body" 2>&1)" || true
  if ! printf '%s' "$out" | grep -q '"acknowledged":true'; then
    [ "$RUNTIME" = compose ] && warn "compose 정의가 구버전이면 path.repo 가 없습니다 — deploy.sh 를 다시 실행하세요"
    die "스냅샷 저장소 등록 실패 ($1 → $2): $out"
  fi
}

latest_snapshot() {  # latest_snapshot <저장소> — SUCCESS 중 가장 최근
  os_curl "$OS/_snapshot/$1/_all" | py '(lambda ok: max(ok, key=lambda s: s["end_time_in_millis"])["snapshot"] if ok else "")([s for s in d.get("snapshots", []) if s.get("state") == "SUCCESS"])'
}

doc_counts() {  # 인덱스별 문서 수 (시스템 인덱스 제외) — "인덱스<TAB>건수", 정렬
  os_curl "$OS/_cat/indices?h=index,docs.count" | awk '$1 !~ /^\./ && NF == 2 {print $1 "\t" $2}' | LC_ALL=C sort
}

# ---------- 정합성 목록 ----------
# 목록 형식: 상대경로 <TAB> 바이트 <TAB> sha256 — LexAI 이관 패키지와 같은 형식.
# 계약 요구사항(수행계획서 3-3)인 "용량 · 파일 개수 · 해시" 3종을 풀자마자 그 자리에서 대조한다.
# DB 파일은 제외 — 업로드 디렉토리와 같은 곳에 있지만 VACUUM INTO 로 따로 뜬다.
# SUDO_DIR 을 앞에 붙여 부르면 그 권한으로 읽는다 (예: SUDO_DIR=sudo verify_manifest …).
list_files() {  # list_files <디렉토리> — NUL 구분 상대경로 (정렬)
  ${SUDO_DIR:-} find "$1" -type f ! -name "$MANIFEST_NAME" ! -name "$DB_NAME" ! -name "$DB_NAME-*" -printf '%P\0' \
    | LC_ALL=C sort -z
}

write_manifest() {  # write_manifest <디렉토리> — 목록을 stdout 으로
  local dir="$1" f
  list_files "$dir" | while IFS= read -r -d '' f; do
    printf '%s\t%s\t%s\n' "$f" "$(${SUDO_DIR:-} stat -c %s "$dir/$f")" \
      "$(${SUDO_DIR:-} sha256sum "$dir/$f" | cut -d' ' -f1)"
  done
}

verify_manifest() {  # verify_manifest <디렉토리> — 안에 든 contents.tsv 와 대조
  local dir="$1" man want_n want_b have_n have_b mism bad=0
  man="$(${SUDO_DIR:-} cat "$dir/$MANIFEST_NAME" 2>/dev/null)" \
    || { warn "   목록 파일이 없어 정합성 대조를 건너뜁니다: $dir"; return 0; }
  want_n="$( { printf '%s\n' "$man" | grep -c . ; } || true )"
  want_b="$(printf '%s\n' "$man" | awk -F'\t' '{s+=$2} END{print s+0}')"
  have_n="$(list_files "$dir" | tr -cd '\0' | wc -c | tr -d ' ')"
  have_b="$(${SUDO_DIR:-} find "$dir" -type f ! -name "$MANIFEST_NAME" ! -name "$DB_NAME" ! -name "$DB_NAME-*" -printf '%s\n' \
    | awk '{s+=$1} END{print s+0}')"
  [ "$want_n" = "$have_n" ] || { warn "   파일 개수 불일치: 기대 $want_n / 실제 $have_n"; bad=1; }
  [ "$want_b" = "$have_b" ] || { warn "   총 용량 불일치: 기대 $want_b / 실제 $have_b"; bad=1; }
  if [ "$want_n" -gt 0 ]; then
    mism="$( { printf '%s\n' "$man" | awk -F'\t' 'NF == 3 {print $3 "  " $1}' \
      | ${SUDO_DIR:-} sh -c "cd '$dir' && sha256sum -c --quiet" 2>&1 | head -20; } || true )"
    [ -z "$mism" ] || { warn "   해시 불일치:"; printf '%s\n' "$mism" >&2; bad=1; }
  fi
  [ "$bad" = 0 ] && log "   정합성 대조 통과 — 파일 ${have_n}개 / ${have_b} bytes"
  return "$bad"
}

compress_to() {  # compress_to <출력파일> — stdin 의 tar 를 압축해 쓴다
  # gzip 은 단일 코어라 스냅샷이 크면 수 분씩 걸리고, 이관 당일에는 그 시간이 중단 시간에
  # 그대로 더해진다. pigz 가 있으면 코어 수만큼 병렬로 압축한다 (출력은 같은 gzip 형식).
  if [ "${ARCHIVE_COMPRESS:-auto}" = none ]; then
    cat > "$1"           # 이름은 .tar.gz 유지 — 받는 쪽은 tar -xf 로 형식을 자동 판별한다
  elif command -v pigz >/dev/null 2>&1; then
    pigz -p "$(nproc)" > "$1"
  else
    warn "   pigz 가 없어 단일 코어로 압축합니다 (sudo apt-get install -y pigz)"
    gzip > "$1"
  fi
}

pkg_value() {  # pkg_value <패키지디렉토리> <키> — package.env 에서 값 하나 (마지막 값 우선)
  { grep "^$2=" "$1/package.env" 2>/dev/null | tail -1 | cut -d= -f2- ; } || true
}

# ---------- 오브젝트 스토리지 ----------
ensure_cli() {  # ensure_cli aws|gsutil — 순정 Ubuntu 에는 없으므로 그 자리에서 설치
  command -v "$1" >/dev/null 2>&1 && return 0
  log "   $1 설치"
  case "$1" in
    aws)
      { $AS_ROOT apt-get update -qq && $AS_ROOT env DEBIAN_FRONTEND=noninteractive apt-get install -y -q awscli; } >/dev/null 2>&1 \
        || $AS_ROOT snap install aws-cli --classic >/dev/null 2>&1 || true ;;   # 24.04 는 apt 패키지가 없다
    gsutil)
      $AS_ROOT snap install google-cloud-cli --classic >/dev/null 2>&1 || true ;;
  esac
  hash -r
  command -v "$1" >/dev/null 2>&1 || die "$1 를 설치하지 못했습니다 — 직접 설치한 뒤 다시 실행하세요"
}

aws_s3() {  # aws_s3 <aws s3 인자...> — S3 호환 스토리지(NCP 등)는 S3_ENDPOINT_URL 로
  local args=()
  [ -n "${S3_ENDPOINT_URL:-}" ] && args+=(--endpoint-url "$S3_ENDPOINT_URL")
  aws "${args[@]}" s3 "$@"
}

fetch_one() {  # fetch_one <원본> <받을 파일>
  case "$1" in
    s3://*)              ensure_cli aws;    aws_s3 cp "$1" "$2" --only-show-errors ;;
    gs://*)              ensure_cli gsutil; gsutil -q cp "$1" "$2" ;;
    http://*|https://*)  curl -fsSL "$1" -o "$2" ;;
    *)                   cp "$1" "$2" ;;
  esac
}

# ===========================================================
# backup — 소스에서 패키지 생성
# ===========================================================
cmd_backup() {
  local ts out
  ts="$(date +%Y%m%d%H%M%S)"
  out="${1:-$HOME/widgetrag-backup/$(date +%Y%m%d-%H%M)}"
  setup_runtime
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI 필요 — sudo apt-get install -y sqlite3"
  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    die "출력 디렉토리가 비어 있지 않습니다: $out"
  fi
  mkdir -p "$out"
  out="$(cd "$out" && pwd)"

  local dir db
  dir="$(data_dir)"
  db="$dir/$DB_NAME"
  ${DATA_SUDO} test -f "$db" || die "DB 파일이 없습니다: $db"

  # ----- 1. OpenSearch 스냅샷 (서비스 무중지) -----
  log "1. OpenSearch 스냅샷 ($RUNTIME)"
  ensure_repo_path
  local repo_host="$REPO_HOST/repo" snap="snap-$ts" resp started
  $AS_ROOT mkdir -p "$repo_host"
  $AS_ROOT chown "$REPO_OWNER" "$repo_host"
  register_repo "$SNAPSHOT_REPO" "$REPO_LOC/repo"

  started=$(date +%s)
  resp="$(os_curl -X PUT "$OS/_snapshot/$SNAPSHOT_REPO/$snap?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d '{"indices":"*,-.*","include_global_state":false}' 2>&1)" || true
  printf '%s' "$resp" | grep -q '"state":"SUCCESS"' || die "스냅샷 상태가 SUCCESS 가 아닙니다: $resp"
  log "   $snap ($(( $(date +%s) - started ))초)"

  # 저장소는 증분이라 돌릴 때마다 스냅샷이 쌓인다. 직전 것이 있어야 이관 당일의 두 번째
  # 스냅샷이 변경분만 담으므로 최신 몇 개는 남기고, 그보다 오래된 것만 지운다.
  local snaps total old
  snaps="$( { os_curl "$OS/_cat/snapshots/$SNAPSHOT_REPO?h=id,end_epoch" | sort -k2 -n | awk '{print $1}'; } || true )"
  total="$( { printf '%s\n' "$snaps" | grep -c . ; } || true )"
  if [ "${total:-0}" -gt "$KEEP_SNAPSHOTS" ]; then
    printf '%s\n' "$snaps" | head -n "$(( total - KEEP_SNAPSHOTS ))" | while read -r old; do
      [ -n "$old" ] || continue
      os_curl -X DELETE "$OS/_snapshot/$SNAPSHOT_REPO/$old" >/dev/null || true
      log "   오래된 스냅샷 정리: $old"
    done
  fi

  doc_counts > "$out/doccount.tsv" || die "인덱스 문서 수를 읽지 못했습니다"
  log "   문서 수 기준선: $(awk -F'\t' '{printf "%s %s건  ", $1, $2}' "$out/doccount.tsv")"
  SUDO_DIR="$AS_ROOT" write_manifest "$repo_host" | $AS_ROOT tee "$repo_host/$MANIFEST_NAME" >/dev/null

  # 압축이 몇 분 돌다가 No space left 로 죽으면 그 시간이 통째로 날아간다 — 미리 확인한다.
  local need_kb free_kb
  need_kb=$(( $($AS_ROOT du -sk "$repo_host" | cut -f1) + $(${DATA_SUDO} du -sk "$dir" | cut -f1) ))
  free_kb="$(df -Pk "$out" | awk 'NR == 2 {print $4}')"
  if [ "$free_kb" -lt "$need_kb" ]; then
    rmdir "$out" 2>/dev/null || true
    die "여유 공간 부족 — 필요(최대) ${need_kb}KB / 여유 ${free_kb}KB ($out). 이전 패키지를 지우고 다시 실행하세요"
  fi

  started=$(date +%s)
  $AS_ROOT tar -cf - -C "$repo_host" . | compress_to "$out/opensearch-snapshots.tar.gz"
  log "   아카이브 $(du -h "$out/opensearch-snapshots.tar.gz" | cut -f1) ($(( $(date +%s) - started ))초)"

  # ----- 2. SQLite -----
  # ★ cp 로 뜨면 쓰기 중간 상태가 섞이고 -wal 의 최근 쓰기가 빠진다. VACUUM INTO 는 서비스를
  #   멈추지 않고도 일관된 시점의 단일 파일을 만든다 (-wal/-shm 을 챙길 필요도 없다).
  log "2. SQLite"
  ${DATA_SUDO} sqlite3 "$db" "VACUUM INTO '$out/$DB_NAME';"
  [ -z "$DATA_SUDO" ] || $AS_ROOT chown "$(id -u):$(id -g)" "$out/$DB_NAME"
  [ "$(sqlite3 "$out/$DB_NAME" 'PRAGMA integrity_check;')" = ok ] || die "SQLite 무결성 검사 실패: $out/$DB_NAME"
  local counts
  counts="$(sqlite3 "$out/$DB_NAME" "SELECT 'company ' || (SELECT count(*) FROM company) || ' · member ' || (SELECT count(*) FROM member) || ' · product_item ' || (SELECT count(*) FROM product_item) || ' · chat_log ' || (SELECT count(*) FROM chat_log);")" \
    || die "DB 에 WidgetRAG 테이블이 없습니다: $db"
  log "   $(du -h "$out/$DB_NAME" | cut -f1) — $counts"

  # ----- 3. 업로드 파일 -----
  log "3. 업로드 파일"
  local tmp n_up
  tmp="$(mktemp -d)"
  SUDO_DIR="$DATA_SUDO" write_manifest "$dir" > "$tmp/$MANIFEST_NAME"
  n_up="$( { grep -c . "$tmp/$MANIFEST_NAME"; } || true )"
  ${DATA_SUDO} tar -cf - -C "$dir" --exclude="$DB_NAME" --exclude="$DB_NAME-*" . \
    -C "$tmp" "$MANIFEST_NAME" | compress_to "$out/uploads.tar.gz"
  rm -rf "$tmp"
  log "   파일 ${n_up}개 — $(du -h "$out/uploads.tar.gz" | cut -f1)"

  # ----- 4. 메타데이터 · 체크섬 -----
  log "4. 매니페스트 · 체크섬"
  local os_ver
  os_ver="$(os_curl "$OS" | py 'd["version"]["number"]' 2>/dev/null || echo unknown)"
  cat > "$out/package.env" <<EOF
PACKAGE_FORMAT=1
CREATED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
SOURCE_HOST=$(hostname)
SOURCE_RUNTIME=$RUNTIME
SOURCE_STORAGE_BASE=$STORAGE_BASE
SNAPSHOT_NAME=$snap
OPENSEARCH_VERSION=$os_ver
EOF
  ( cd "$out" && sha256sum package.env doccount.tsv "$DB_NAME" uploads.tar.gz opensearch-snapshots.tar.gz > checksums.sha256 )

  cat > "$out/MANIFEST.txt" <<EOF
WidgetRAG 이관 패키지
생성 시각   : $(date '+%Y-%m-%d %H:%M:%S %Z')
생성 호스트 : $(hostname) ($RUNTIME)

내용
  opensearch-snapshots.tar.gz  색인 스냅샷 $snap — $(awk -F'\t' '{printf "%s %s건 ", $1, $2}' "$out/doccount.tsv")
  widgetrag.db                 SQLite — $counts
  uploads.tar.gz               업로드 파일 ${n_up}개
  doccount.tsv                 인덱스별 문서 수 (복원 후 대조)
  package.env                  원본 형태 · 업로드 경로 접두사 ($STORAGE_BASE)
  checksums.sha256             위 파일들의 SHA-256

정합성 확인
  전송 직후   sha256sum -c checksums.sha256
  복원 직후   package.sh restore 가 풀린 파일의 개수 · 총 용량 · 해시를 대조한다
              (목록 파일 contents.tsv 가 두 아카이브 안에 함께 들어 있다)

포함하지 않은 것
  LLM · 임베딩 모델   타겟에서 자동으로 다시 받는다
  관리자 비밀번호     비밀값이라 제외 — 이관된 DB 의 기존 계정은 소스의 비밀번호로 로그인한다

타겟에서 (패키지를 오브젝트 스토리지에 올린 뒤)
  A  curl -fsSL <raw>/scripts/local/bootstrap.sh | SNAPSHOT_URI=<이 패키지 위치> bash
  B  curl -fsSL <raw>/scripts/compose/deploy.sh  | SNAPSHOT_URI=<이 패키지 위치> bash
EOF

  echo
  log "패키지 완료: $out"
  du -h "$out"/* | sed 's/^/  /'

  if [ -n "${UPLOAD_URI:-}" ]; then
    log "업로드: $UPLOAD_URI"
    case "$UPLOAD_URI" in
      s3://*) ensure_cli aws;    aws_s3 cp --recursive "$out" "${UPLOAD_URI%/}/" --only-show-errors ;;
      gs://*) ensure_cli gsutil; gsutil -q -m cp -r "$out"/* "${UPLOAD_URI%/}/" ;;
      *)      die "UPLOAD_URI 는 s3:// 또는 gs:// 만 지원합니다: $UPLOAD_URI" ;;
    esac
    log "타겟에서: SNAPSHOT_URI=${UPLOAD_URI%/} 로 진입물 실행"
  else
    echo
    echo "  전송 예: aws s3 cp --recursive $out s3://<버킷>/widgetrag/$(basename "$out")/"
    echo "  또는  : UPLOAD_URI=s3://<버킷>/widgetrag/$(basename "$out") bash $0 backup"
  fi
}

# ===========================================================
# fetch — 타겟에서 패키지 수신 + 체크섬 확인
# ===========================================================
cmd_fetch() {
  local uri="${1:-}" dir="${2:-$HOME/widgetrag-package}" f
  [ -n "$uri" ] || die "사용법: $0 fetch <URI> [받을디렉토리]"
  uri="${uri%/}"
  mkdir -p "$dir"

  # 같은 곳에서 이미 받아 온전하면 다시 받지 않는다 (재부팅 후 재개 · 재실행)
  if [ "$(cat "$dir/.source" 2>/dev/null)" = "$uri" ] \
     && ( cd "$dir" && sha256sum -c --quiet checksums.sha256 ) >/dev/null 2>&1; then
    log "이미 받은 패키지 — 체크섬 일치, 다시 받지 않습니다: $dir"
    return 0
  fi

  rm -f "$dir/.source" "$dir/.restored"
  log "패키지 수신: $uri → $dir"
  for f in "${PKG_FILES[@]}"; do
    if [ "$f" = MANIFEST.txt ]; then           # 사람이 읽는 요약 — 없어도 된다
      fetch_one "$uri/$f" "$dir/$f" 2>/dev/null || rm -f "$dir/$f"
      continue
    fi
    fetch_one "$uri/$f" "$dir/$f" || die "받지 못했습니다: $uri/$f"
  done

  # 전송 손상을 압축 풀기 전에 잡는다. 깨진 아카이브를 풀어봐야 뒤에서 더 알기 어려운
  # 형태로 실패할 뿐이다.
  ( cd "$dir" && sha256sum -c --quiet checksums.sha256 ) || die "체크섬 불일치 — 전송이 온전하지 않습니다 ($dir)"
  echo "$uri" > "$dir/.source"
  log "체크섬 확인 — $(du -sh "$dir" | cut -f1) (원본 $(pkg_value "$dir" SOURCE_HOST) · $(pkg_value "$dir" SOURCE_RUNTIME))"
}

# ===========================================================
# restore — 타겟에 색인 · DB · 업로드 파일 복원
#   앱(backend)이 뜨기 전에 부른다 — backend 는 기동할 때 색인이 없으면 빈 색인을 만들고,
#   DB 가 없으면 빈 DB 와 관리자 계정을 만든다.
# ===========================================================
restore_index() {
  local pkg="$1" idx have has_docs=0 imp_host snap indices resp
  log "색인 복원 ($RUNTIME)"
  ensure_repo_path

  while IFS=$'\t' read -r idx _; do
    [ -n "$idx" ] || continue
    have="$( { os_curl "$OS/$idx/_count" 2>/dev/null | py 'd.get("count", "")' 2>/dev/null; } || true )"
    if [ -n "$have" ] && [ "$have" -gt 0 ] 2>/dev/null; then has_docs=1; fi
  done < "$pkg/doccount.tsv"
  if [ "$has_docs" = 1 ] && [ "${FORCE_RESTORE:-0}" != 1 ]; then
    log "   색인이 이미 있습니다 — 복원 건너뜀 (덮어쓰려면 FORCE_RESTORE=1)"
    return 0
  fi

  imp_host="$REPO_HOST/import"
  $AS_ROOT rm -rf "$imp_host"
  $AS_ROOT mkdir -p "$imp_host"
  $AS_ROOT tar -xf "$pkg/opensearch-snapshots.tar.gz" -C "$imp_host"
  # 컨테이너(uid 1000) ↔ 네이티브(opensearch) 사이를 오가면 소유자가 달라 access_denied 가 난다
  $AS_ROOT chown -R "$REPO_OWNER" "$imp_host"
  SUDO_DIR="$AS_ROOT" verify_manifest "$imp_host" || die "스냅샷 정합성 대조 실패 — 패키지를 다시 받으세요"

  register_repo "$IMPORT_REPO" "$REPO_LOC/import" readonly
  # 패키지마다 스냅샷 이름이 달라(snap-<시각>) 고정할 수 없다 — SUCCESS 중 가장 최근 것
  # (증분 컷오버의 두 번째 스냅샷도 이것). 특정 시점은 SNAPSHOT_NAME 으로 지정.
  snap="${SNAPSHOT_NAME:-}"
  if [ -z "$snap" ]; then
    snap="$(latest_snapshot "$IMPORT_REPO")" || die "스냅샷 목록을 읽지 못했습니다 ($IMPORT_REPO)"
  fi
  [ -n "$snap" ] || die "복원할 스냅샷이 없습니다 — $imp_host 내용을 확인하세요"
  log "   스냅샷 선택: $snap"

  # 복원은 열린 동명 인덱스가 있으면 거부된다. 비어 있는 것(backend 가 먼저 떠서 만든 빈 색인 등)이나
  # FORCE_RESTORE=1 일 때만 여기까지 오므로 지우고 진행한다.
  indices="$(os_curl "$OS/_snapshot/$IMPORT_REPO/$snap" | py '"\n".join(d["snapshots"][0]["indices"])')" \
    || die "스냅샷 $snap 의 인덱스 목록을 읽지 못했습니다"
  for idx in $indices; do
    case "$idx" in .*) continue ;; esac
    if [ "$(os_curl -o /dev/null -w '%{http_code}' "$OS/$idx")" = 200 ]; then
      warn "   기존 인덱스를 지우고 복원합니다: $idx"
      os_curl -X DELETE "$OS/$idx" >/dev/null
    fi
  done

  log "   복원 중 (wait_for_completion)"
  resp="$(os_curl -X POST "$OS/_snapshot/$IMPORT_REPO/$snap/_restore?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d '{"indices":"*,-.*","include_global_state":false}' 2>&1)" || true
  [ "$(printf '%s' "$resp" | py 'd.get("snapshot", {}).get("shards", {}).get("failed", -1)' 2>/dev/null)" = 0 ] \
    || die "복원 실패: $resp"

  # 인덱스별 문서 수를 소스 기준선과 대조한다 (샤드가 열리는 동안 잠시 기다린다)
  for _ in $(seq 1 10); do
    if diff <(cat "$pkg/doccount.tsv") <(doc_counts | awk -F'\t' 'NR == FNR {want[$1]; next} ($1 in want)' "$pkg/doccount.tsv" -) >/dev/null; then
      log "   문서 수 일치 — $(awk -F'\t' '{printf "%s %s건  ", $1, $2}' "$pkg/doccount.tsv")"
      return 0
    fi
    sleep 3
  done
  diff <(cat "$pkg/doccount.tsv") <(doc_counts) || true
  die "문서 수 불일치 — 위 diff 확인 (좌: 소스 / 우: 타겟)"
}

restore_data() {
  local pkg="$1" dir db tmp from ts
  log "DB · 업로드 파일 복원 ($RUNTIME)"
  dir="$(data_dir)"
  db="$dir/$DB_NAME"

  if ${DATA_SUDO} test -f "$db"; then
    if [ "${FORCE_RESTORE:-0}" != 1 ]; then
      log "   DB 가 이미 있습니다 — 복원 건너뜀 (덮어쓰려면 FORCE_RESTORE=1)"
      return 0
    fi
  fi
  if backend_running; then
    [ "$RUNTIME" = compose ] && die "backend 가 실행 중입니다 — 먼저: cd $COMPOSE_DIR && docker compose stop backend"
    die "백엔드가 실행 중입니다 — 먼저: sudo systemctl stop widgetrag-backend"
  fi

  ts="$(date +%Y%m%d%H%M%S)"
  if ${DATA_SUDO} test -f "$db"; then          # FORCE_RESTORE=1 — 기존 내용은 비켜둔다
    if [ "$RUNTIME" = compose ]; then
      $AS_ROOT tar -czf "$COMPOSE_DIR/upload-data.bak-$ts.tar.gz" -C "$dir" .
      $AS_ROOT find "$dir" -mindepth 1 -delete
      warn "   기존 볼륨 내용 백업: $COMPOSE_DIR/upload-data.bak-$ts.tar.gz"
    else
      mv "$dir" "$dir.bak-$ts" && mkdir -p "$dir"
      warn "   기존 데이터 백업: $dir.bak-$ts"
    fi
  fi

  tmp="$(mktemp -d)"
  tar -xf "$pkg/uploads.tar.gz" -C "$tmp"
  verify_manifest "$tmp" || { rm -rf "$tmp"; die "업로드 파일 정합성 대조 실패 — 패키지를 다시 받으세요"; }
  rm -f "$tmp/$MANIFEST_NAME"
  cp "$pkg/$DB_NAME" "$tmp/$DB_NAME"
  [ "$(sqlite3 "$tmp/$DB_NAME" 'PRAGMA integrity_check;')" = ok ] || { rm -rf "$tmp"; die "SQLite 무결성 검사 실패"; }
  # VACUUM INTO 로 뜬 파일은 롤백 저널 모드다 — 소스와 같은 WAL 로 되돌려 둔다
  # (앱도 JDBC URL 의 journal_mode=WAL 로 바꾸지만, 기동 전 검증 · 동시 접근을 위해 미리 맞춘다)
  sqlite3 "$tmp/$DB_NAME" 'PRAGMA journal_mode=WAL;' >/dev/null

  # ★ product.storage_path 는 업로드 파일의 절대경로다. 저장 경로가 다른 곳으로 옮기면
  #   (A ↔ B, 또는 CSP 마다 기본 사용자가 달라 $HOME 이 바뀌는 경우) 옛 경로가 남아,
  #   상품 파일을 지울 때 파일이 에러 없이 남는다. 접두사만 타겟 경로로 바꿔 적는다.
  from="$(pkg_value "$pkg" SOURCE_STORAGE_BASE)"
  if [ -z "$from" ]; then
    warn "   package.env 에 SOURCE_STORAGE_BASE 가 없어 경로 재작성을 건너뜁니다"
  elif [ "$from" = "$STORAGE_BASE" ]; then
    log "   업로드 경로가 같습니다 ($STORAGE_BASE) — 재작성 없음"
  else
    local f="${from//\'/\'\'}" t="${STORAGE_BASE//\'/\'\'}" n
    n="$(sqlite3 "$tmp/$DB_NAME" "UPDATE product SET storage_path = '$t' || substr(storage_path, length('$f') + 1) WHERE substr(storage_path, 1, length('$f') + 1) = '$f' || '/'; SELECT changes();")"
    log "   업로드 경로 재작성 ${n}건: $from → $STORAGE_BASE"
  fi

  ${DATA_SUDO} cp -a "$tmp/." "$dir/"
  # compose 볼륨은 root 로 채웠으므로 backend(appuser)가 쓸 수 있게 루트 디렉터리째 넘긴다.
  # 빠뜨리면 -wal 생성부터 막혀 backend 가 DB 를 열지 못한다.
  ${DATA_SUDO} chown -R "$DATA_OWNER" "$dir"
  rm -rf "$tmp"

  log "   $(${DATA_SUDO} sqlite3 "$db" "SELECT 'company ' || (SELECT count(*) FROM company) || ' · member ' || (SELECT count(*) FROM member) || ' · product_item ' || (SELECT count(*) FROM product_item) || ' · chat_log ' || (SELECT count(*) FROM chat_log);")"
}

cmd_restore() {
  local pkg="${1:-}" what="${2:-all}"
  [ -n "$pkg" ] || die "사용법: $0 restore <패키지디렉토리> [all|index|data]"
  [ -f "$pkg/checksums.sha256" ] || die "패키지가 아닙니다 (checksums.sha256 없음): $pkg"
  pkg="$(cd "$pkg" && pwd)"
  setup_runtime
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI 필요 — sudo apt-get install -y sqlite3"
  ( cd "$pkg" && sha256sum -c --quiet checksums.sha256 ) || die "체크섬 불일치 — 패키지를 다시 받으세요: $pkg"

  local started; started=$(date +%s)
  case "$what" in
    all)   restore_index "$pkg"; restore_data "$pkg" ;;
    index) restore_index "$pkg" ;;
    data)  restore_data "$pkg" ;;
    *)     die "복원 대상은 all · index · data 중 하나입니다: $what" ;;
  esac
  touch "$pkg/.restored"
  log "복원 단계 완료 ($what, $(( $(date +%s) - started ))초)"
}

case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *)
    cat >&2 <<EOF
사용법:
  $0 backup [출력디렉토리]                 소스 — 패키지 생성 (UPLOAD_URI=s3://… 면 업로드까지)
  $0 fetch <URI> [받을디렉토리]            타겟 — 패키지 수신 + 체크섬 확인
  $0 restore <패키지디렉토리> [all|index|data]   타겟 — 앱 기동 전에 복원
EOF
    exit 1 ;;
esac
