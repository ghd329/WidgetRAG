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
#     bash package.sh compare <패키지디렉토리> [--evidence 디렉토리]   # 타겟 — 이관 동등성 비교 (verify.sh COMPARE=1 이 부른다)
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
#   이관 동등성 기준선 (PACKAGE_FORMAT=2 — 구형 fetch 는 모르는 파일이라 받지 않고, 5종 체크섬은 그대로다)
#     package-files.tsv            아래 파일 전부의 이름 · 바이트 · sha256 — package.env 가 이 목록의 sha256 을 담는다
#     baseline-db.tsv              DB 논리 해시 (테이블별 행 수 · 바이트 · sha256 + _schema)
#     baseline-rag.tsv             색인 내용 해시 (인덱스별 + 매핑 · 설정) — baseline-rag-docs.tsv 는 문서별 해시
#     fingerprint-source.txt       소스 환경 지문 (Ollama · 모델 digest · GPU · 생성 파라미터 — 화이트리스트 키만)
#     golden.json                  골든 질문 · 응답 (GOLDEN=1) — 타겟 LLM 응답 완전 일치 비교(테스트2)의 기준
#   해시 · 판정 계산은 같은 디렉토리의 migcheck.py 가 한다 (compose 는 deploy.sh 가 함께 받는다).
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
#
#   이관 동등성 (backup · compare)
#     BASELINE=0         기준선(DB · 색인 해시 · 서비스 목록 · 지문)을 뜨지 않는다 (기본 1)
#     BASELINE_RAG=0     색인 내용 해시만 끈다 — 타겟은 문서 수만 대조 (기본 1)
#     GOLDEN=1           골든 응답 생성 (기본 0) — 소스 AI 서버가 LLM_TEMPERATURE=0 LLM_SEED=42 로 떠 있어야 한다
#     GOLDEN_REPEAT      골든 반복 횟수 (기본 2 — 회차끼리 같아야 ok)
#     GOLDEN_QUESTIONS_FILE  골든 질문 파일 (한 줄에 하나 · # 주석) — 기본 5문항
#     GOLDEN_CLIENT_CODE 골든 질문의 clientCode (기본: 상품이 가장 많은 승인 업체)
#     GOLDEN_CHECK=0     compare 에서 테스트2(골든 비교)를 건너뛴다
#     EXPECT_SERVICE_COUNT  기준선 없는 구형 패키지의 T1-1 기대 서비스 수
#     PORT_AI · PORT_OLLAMA · PORT_FRONTEND · VENV_DIR   native 의 포트 · AI 서버 venv (기본 8000 · 11434 · 80 · ai-server/.venv)
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

# 이관 동등성 계산기 — 해시 · 판정 로직은 migcheck.py 한 곳에 둔다 (package.sh · verify.sh 공용)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGCHECK="$SCRIPT_DIR/migcheck.py"
WORK_TMP=""; CMP_TMP=""; CMP_ROWS=""       # backup · compare 의 임시 디렉토리 (종료 시 정리)
IDX_STATE=""; DATA_STATE=""; RESTORED_SNAPSHOT=""   # restore 결과 → .restore-state
PKG_BAD=""                                 # verify_pkg_files 가 불일치로 본 파일 이름

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
      FRONT="http://127.0.0.1:${PORT_FRONTEND:-80}"   # verify.sh 와 같은 규칙
      SOURCE_FORM_NAME="shell-native"                 # verify.sh FORM 과 같은 이름
      ;;
    compose)
      STORAGE_BASE="$COMPOSE_STORAGE_BASE"
      REPO_HOST="$COMPOSE_DIR/snapshots"; REPO_LOC="$COMPOSE_REPO_MOUNT"
      REPO_OWNER="$OPENSEARCH_UID:$OPENSEARCH_UID"
      # 볼륨 마운트 지점(/var/lib/docker/volumes)은 root 만 들어갈 수 있다
      DATA_OWNER="$BACKEND_UID:$BACKEND_UID"; DATA_SUDO="$AS_ROOT"
      FRONT="http://127.0.0.1:80"
      SOURCE_FORM_NAME="docker-compose"
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

# ---------- 이관 동등성 (기준선 · 비교) ----------
# 해시 · 판정은 migcheck.py 가 하고, 여기서는 실행 형태에 맞게 데이터를 모아 넘긴다.
# 이 절의 함수는 compare(불일치로 죽으면 안 된다) 에서도 불리므로 die 하지 않는다 —
# 실패는 스스로 삼키거나 종료코드로 돌려준다 (need_migcheck 만 예외).
# ★ set -e 는 `if`/`||` 문맥에서 불린 함수 안에서 꺼진다 — 그래서 명령마다 종료코드를 직접 본다.
need_migcheck() {
  command -v python3 >/dev/null 2>&1 || die "python3 필요 — sudo apt-get install -y python3"
  [ -f "$MIGCHECK" ] || die "migcheck.py 가 없습니다 — package.sh 와 같은 곳에 두세요 ($MIGCHECK)"
}
mc() { python3 "$MIGCHECK" "$@"; }

cleanup_tmp() {
  [ -z "$WORK_TMP" ] || rm -rf "$WORK_TMP"
  [ -z "$CMP_TMP" ] || rm -rf "$CMP_TMP"
}

kv_get() {  # kv_get <파일> <키> — key=value 파일에서 값 하나 (마지막 값 우선, 없으면 빈 값)
  { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- ; } || true
}
line_value() {  # line_value <여러 줄 텍스트> <키> — "키=값" 줄에서 값 (마지막 값 우선, 없으면 빈 값)
  { printf '%s\n' "$1" | grep "^$2=" | tail -1 | cut -d= -f2- ; } || true
}
kv_set() {  # kv_set <파일> <키> <값> — 키가 있으면 그 자리에서 바꾸고 없으면 덧붙인다 (다른 키는 유지)
  local f="$1" tmp="$1.tmp.$$"
  [ -f "$f" ] || : > "$f"
  # 값은 ENVIRON 으로 넘긴다 — awk -v 는 역슬래시를 해석해 값을 바꾼다
  KV_K="$2" KV_V="$3" awk 'BEGIN {k = ENVIRON["KV_K"]; v = ENVIRON["KV_V"]}
    index($0, k "=") == 1 {if (!done) print k "=" v; done = 1; next}
    {print}
    END {if (!done) print k "=" v}' "$f" > "$tmp" && mv "$tmp" "$f"
}
num() {  # num <값> — 음이 아닌 정수가 아니면 0 (빈 값으로 산술하면 셸이 죽는다)
  case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$((10#$1))" ;; esac
}
json_get() {  # json_get <python 식> — stdin JSON 에서 값 (실패하면 빈 값 · 종료코드 0)
  python3 -c "import sys,json
try:
    d = json.load(sys.stdin); print($1)
except Exception:
    pass" 2>/dev/null || true
}

pkg_name_ok() {  # pkg_name_ok <이름> — 패키지 파일은 평면 · 점으로 시작하지 않음 (목록으로 디렉토리 밖을 건드리지 못하게)
  case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

verify_pkg_files() {  # verify_pkg_files <디렉토리> — FORMAT≥2 면 package-files.tsv 전 파일의 bytes · sha256 대조 (FORMAT<2 는 0)
  # package.env(체크섬 5종에 포함) → PACKAGE_FILES_SHA256 → package-files.tsv → 파일마다 해시, 로 이어지는 사슬.
  # 불일치하면 PKG_BAD 에 파일 이름을 남기고 1.
  local dir="$1" fmt want name bytes sha
  PKG_BAD=""
  fmt="$(num "$(pkg_value "$dir" PACKAGE_FORMAT)")"
  [ "$fmt" -ge 2 ] || return 0
  want="$(pkg_value "$dir" PACKAGE_FILES_SHA256)"
  PKG_BAD="package-files.tsv"
  [ -n "$want" ] && [ -f "$dir/package-files.tsv" ] || return 1
  [ "$(sha256sum "$dir/package-files.tsv" 2>/dev/null | cut -d' ' -f1)" = "$want" ] || return 1
  while IFS=$'\t' read -r name bytes sha; do
    [ -n "$name" ] || continue
    PKG_BAD="$name"
    pkg_name_ok "$name" && [ -f "$dir/$name" ] || return 1
    [ "$(stat -c %s "$dir/$name" 2>/dev/null)" = "$bytes" ] || return 1
    [ "$(sha256sum "$dir/$name" 2>/dev/null | cut -d' ' -f1)" = "$sha" ] || return 1
  done < "$dir/package-files.tsv"
  PKG_BAD=""
  return 0
}

ai_curl() {  # ai_curl <경로> [curl 인자...] — AI 서버(ai-server) 호출
  local path="$1"; shift
  if [ "$RUNTIME" = compose ]; then
    dc exec -T ai-server curl -sS --max-time 200 "http://localhost:8000$path" "$@" </dev/null
  else
    curl -sS --max-time 200 "http://127.0.0.1:${PORT_AI:-8000}$path" "$@"
  fi
}
ollama_curl() {  # ollama_curl <경로> [curl 인자...] — Ollama API (compose 는 llm 포트를 열지 않으므로 ai-server 안에서)
  local path="$1"; shift
  if [ "$RUNTIME" = compose ]; then
    dc exec -T ai-server curl -sS --max-time 60 "http://llm:11434$path" "$@" </dev/null
  else
    curl -sS --max-time 60 "http://127.0.0.1:${PORT_OLLAMA:-11434}$path" "$@"
  fi
}

llm_model_name() {  # AI 서버가 쓰는 LLM 모델 (/health — 못 읽으면 OLLAMA_MODEL)
  local m
  m="$( { ai_curl /health 2>/dev/null | json_get 'd.get("llm_model") or ""'; } )" || m=""
  printf '%s\n' "${m:-${OLLAMA_MODEL:-gemma3:4b}}"
}

llm_unload() {  # llm_unload <모델> — 모델을 내려 다음 호출을 콜드 로드로 (비면 0, 30초 안에 안 비면 1)
  # 적재 상태 · 앞선 요청의 KV 캐시에 따라 같은 입력에도 출력이 갈릴 수 있어, 비교 호출마다 같은 조건을 만든다.
  local body n
  body="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "keep_alive": 0}))' "$1")" || return 1
  ollama_curl /api/generate -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    n="$( { ollama_curl /api/ps 2>/dev/null | json_get 'len(d.get("models") or [])'; } )" || n=""
    [ "$n" = 0 ] && return 0
    sleep 1
  done
  return 1
}

ollama_processor() {  # 적재된 모델의 GPU 적재율 (/api/ps size_vram/size — ollama ps 의 PROCESSOR 열과 같은 뜻)
  local v
  v="$( { ollama_curl /api/ps 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin).get("models") or []
if m:
    s, v = m[0].get("size") or 0, m[0].get("size_vram") or 0
    print("CPU" if s <= 0 or v <= 0 else "100% GPU" if v >= s else "%d%% GPU" % (v * 100 // s))
' 2>/dev/null; } )" || v=""
  printf '%s\n' "${v:-unavailable}"
}

front_chat() {  # front_chat <clientCode> <질문> <접두사> — 위젯 경로(프론트 /api 프록시) 응답을 <접두사>.json · .code 로
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"clientCode": sys.argv[1], "question": sys.argv[2]}, ensure_ascii=False))' "$1" "$2")" || body=""
  curl -s -o "$3.json" -w '%{http_code}' --max-time 200 -X POST "$FRONT/api/chat" \
    -H 'Content-Type: application/json' -d "$body" > "$3.code" 2>/dev/null || true
  [ -s "$3.code" ] || printf '000' > "$3.code"
  [ -f "$3.json" ] || : > "$3.json"
}

ai_generate() {  # ai_generate <본문 JSON> <접두사> — ai-server /generate 직접 호출 (L2: 검색을 뺀 생성 계층만)
  # compose 에서 -o 는 컨테이너 안 경로가 되므로 본문은 stdout 으로 받아 호스트 파일에 쓰고,
  # 상태 코드는 끝줄(-w '\n%{http_code}')에서 떼어 낸다 (native 도 같은 방식).
  local raw="$2.raw" size code=""
  ai_curl /generate -H 'Content-Type: application/json' -d "$1" -w '\n%{http_code}' > "$raw" 2>/dev/null || true
  size="$(num "$(stat -c %s "$raw" 2>/dev/null)")"
  if [ "$size" -ge 4 ]; then code="$(tail -c 3 "$raw" 2>/dev/null)" || code=""; fi
  case "$code" in
    [0-9][0-9][0-9]) head -c "$((size - 4))" "$raw" > "$2.json" 2>/dev/null || : > "$2.json" ;;
    *)               code=000; : > "$2.json" ;;
  esac
  printf '%s' "$code" > "$2.code"
  rm -f "$raw"
}

list_services() {  # 실행 중인 서비스(compose) · 유닛(native) 이름 — 한 줄에 하나 (실패하면 빈 출력)
  # compose 는 프로젝트 범위만 — 전역 docker ps 는 GPU 확인용 --rm 컨테이너 같은 무관한 것이 섞인다.
  if [ "$RUNTIME" = compose ]; then
    { dc ps --status running --format '{{.Service}}'; } 2>/dev/null || true
  else
    { systemctl list-units --type=service --state=active --no-legend --plain \
        opensearch.service ollama.service 'widgetrag-*.service' | awk '{print $1}'; } 2>/dev/null || true
  fi
}

os_scroll_dump() {  # os_scroll_dump <인덱스> <디렉토리> — 문서 전부를 scroll 로 받아 page-NNNN.json 으로 (오류면 1)
  # _doc 정렬이라 fielddata 가 필요 없다 (순서는 migcheck 가 _id 로 다시 맞춘다).
  # 본문은 -d 인자로 — compose 의 os_curl 은 stdin 을 /dev/null 로 막는다.
  local idx="$1" d="$2" n=1 page info sid="" s hits rc=0
  page="$d/page-0001.json"
  os_curl -X POST "$OS/$idx/_search?scroll=2m" -H 'Content-Type: application/json' \
    -d '{"size":500,"sort":["_doc"],"_source":true,"track_total_hits":true}' > "$page" 2>/dev/null || rc=1
  while [ "$rc" = 0 ]; do
    # 오류 응답이면 실패, 아니면 "<scroll_id><TAB><이번 페이지 건수>"
    info="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(d, dict) or "error" in d or "hits" not in d:
    sys.exit(1)
print("%s\t%d" % (d.get("_scroll_id") or "", len(d["hits"]["hits"])))
' "$page" 2>/dev/null)" || { rc=1; break; }
    s="${info%%$'\t'*}"; hits="$(num "${info##*$'\t'}")"
    [ -z "$s" ] || sid="$s"
    [ "$hits" -gt 0 ] || break
    [ -n "$sid" ] || { rc=1; break; }
    n=$((n + 1))
    # 중간에 끊긴 목록으로 해시를 내면 안 된다 — 한도를 넘으면 실패로 본다
    [ "$n" -le 10000 ] || { rc=1; break; }
    page="$d/page-$(printf '%04d' "$n").json"
    os_curl -X POST "$OS/_search/scroll" -H 'Content-Type: application/json' \
      -d "{\"scroll\":\"2m\",\"scroll_id\":\"$sid\"}" > "$page" 2>/dev/null || { rc=1; break; }
  done
  if [ -n "$sid" ]; then
    os_curl -X DELETE "$OS/_search/scroll" -H 'Content-Type: application/json' \
      -d "{\"scroll_id\":\"$sid\"}" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

rag_hash_all() {  # rag_hash_all <out.tsv> <docs.tsv> — 인덱스별 내용 해시 + 매핑 · 설정 해시 (실패하면 1)
  local out="$1" docs="$2" t idxs idx rc=0
  # 호출자의 임시 디렉토리(종료 시 cleanup_tmp 가 지움) 안에 만든다 — 스크롤 도중 끊겨도(Ctrl-C · 이관 도구
  # 타임아웃) 벡터가 든 큰 페이지가 /tmp 에 남지 않게
  t="$(mktemp -d "${CMP_TMP:-${WORK_TMP:-${TMPDIR:-/tmp}}}/rag.XXXXXX")" || return 1
  idxs="$(doc_counts 2>/dev/null | cut -f1)" || rc=1
  : > "$docs" || rc=1
  : > "$t/rows.tsv"
  for idx in $idxs; do
    [ "$rc" = 0 ] || break
    mkdir -p "$t/pages" || { rc=1; break; }
    os_scroll_dump "$idx" "$t/pages" || { rc=1; break; }
    mc rag-hash --index "$idx" --pages-dir "$t/pages" --docs-out "$docs" >> "$t/rows.tsv" || { rc=1; break; }
    rm -rf "$t/pages"          # 벡터가 든 페이지는 크다 — 인덱스마다 바로 지운다
    os_curl "$OS/$idx/_mapping" > "$t/mapping.json" 2>/dev/null || { rc=1; break; }
    os_curl "$OS/$idx/_settings" > "$t/settings.json" 2>/dev/null || { rc=1; break; }
    mc index-meta --index "$idx" --mapping "$t/mapping.json" --settings "$t/settings.json" >> "$t/rows.tsv" || { rc=1; break; }
  done
  if [ "$rc" = 0 ]; then
    { LC_ALL=C sort "$t/rows.tsv" > "$out" && LC_ALL=C sort -o "$docs" "$docs"; } || rc=1
  fi
  rm -rf "$t"
  return "$rc"
}

fp_clean() {  # fp_clean <값> — 지문 값 한 줄로 (첫 줄만 · 탭은 공백, 비면 unavailable)
  local v="${1%%$'\n'*}"
  v="${v//$'\t'/ }"; v="${v//$'\r'/}"
  printf '%s' "${v:-unavailable}"
}

fingerprint() {  # fingerprint <out.txt> — 환경 지문 key=value (최선 노력 — 절대 die 하지 않는다, 못 얻은 값은 unavailable)
  # 비밀값이 섞이지 않게 화이트리스트 키만 하나씩 읽는다 (env 파일 · /proc environ 을 통째로 읽지 않는다).
  local out="$1" health mname body code_ref os_ver ollama_ver digest show np gl gpu driver vers pyv tv stv py_bin
  health="$(ai_curl /health 2>/dev/null)" || health=""
  mname="$(printf '%s' "$health" | json_get 'd.get("llm_model") or ""')"
  mname="${mname:-${OLLAMA_MODEL:-gemma3:4b}}"      # digest · show 조회용 (llm_model 값 자체는 /health 그대로)

  if [ "$RUNTIME" = compose ]; then
    code_ref="$( { $AS_ROOT grep '^IMAGE_TAG=' "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2-; } 2>/dev/null )" || code_ref=""
  else
    code_ref="$(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD 2>/dev/null)" || code_ref=""
  fi
  os_ver="$( { os_curl "$OS" 2>/dev/null | json_get 'd["version"]["number"]'; } )" || os_ver=""
  ollama_ver="$( { ollama_curl /api/version 2>/dev/null | json_get 'd.get("version") or ""'; } )" || ollama_ver=""
  digest="$( { ollama_curl /api/tags 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
names = (want, want + ":latest")
for m in json.load(sys.stdin).get("models") or []:
    if m.get("name") in names or m.get("model") in names:
        print(m.get("digest") or "")
        break
' "$mname" 2>/dev/null; } )" || digest=""
  # /api/show 는 수정 시각 등 환경마다 다른 값도 담는다 — 출력을 정하는 template · parameters · details 만 해시한다
  body="$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1]}))' "$mname" 2>/dev/null)" || body=""
  show="$( { ollama_curl /api/show -H 'Content-Type: application/json' -d "$body" 2>/dev/null | python3 -c '
import hashlib, json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict) or "error" in d:
    sys.exit(1)
c = json.dumps({k: d.get(k) for k in ("template", "parameters", "details")},
               sort_keys=True, ensure_ascii=False, separators=(",", ":"))
print(hashlib.sha256(c.encode("utf-8")).hexdigest())
' 2>/dev/null; } )" || show=""

  if [ "$RUNTIME" = compose ]; then
    np="$(dc exec -T ai-server printenv LLM_NUM_PREDICT </dev/null 2>/dev/null)" || np=""
  else
    np="$( { $AS_ROOT grep '^LLM_NUM_PREDICT=' /etc/widgetrag/widgetrag.env | tail -1 | cut -d= -f2-; } 2>/dev/null )" || np=""
  fi
  np="${np:-200}"                                    # ai-server 기본값 (main_exaone.py)

  if command -v nvidia-smi >/dev/null 2>&1; then
    # head 대신 awk — head 가 먼저 닫으면 SIGPIPE 로 pipefail 이 값을 버린다
    gl="$( { nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | awk 'NR == 1'; } 2>/dev/null )" || gl=""
    case "$gl" in
      *,*) gpu="${gl%%,*}"; driver="${gl#*,}"; driver="${driver# }" ;;
      *)   gpu=""; driver="" ;;
    esac
  else
    gpu=none; driver=none
  fi

  local pycode='import sys
print(sys.version.split()[0])
try:
    import importlib.metadata as m
except Exception:
    m = None
for p in ("torch", "sentence-transformers"):
    try:
        print(m.version(p))
    except Exception:
        print("unavailable")'
  vers=""
  if [ "$RUNTIME" = compose ]; then
    vers="$(dc exec -T ai-server python -c "$pycode" </dev/null 2>/dev/null)" || vers=""
  else
    py_bin="${VENV_DIR:-$SCRIPT_DIR/../ai-server/.venv}/bin/python"
    if [ -x "$py_bin" ]; then vers="$("$py_bin" -c "$pycode" 2>/dev/null)" || vers=""; fi
  fi
  pyv="$(printf '%s\n' "$vers" | sed -n 1p)"; tv="$(printf '%s\n' "$vers" | sed -n 2p)"; stv="$(printf '%s\n' "$vers" | sed -n 3p)"

  {
    printf 'runtime=%s\n'               "$(fp_clean "$RUNTIME")"
    printf 'form=%s\n'                  "$(fp_clean "$SOURCE_FORM_NAME")"
    printf 'hostname=%s\n'              "$(fp_clean "$(hostname 2>/dev/null || true)")"
    printf 'code_ref=%s\n'              "$(fp_clean "$code_ref")"
    printf 'opensearch_version=%s\n'    "$(fp_clean "$os_ver")"
    printf 'ollama_version=%s\n'        "$(fp_clean "$ollama_ver")"
    printf 'llm_model=%s\n'             "$(fp_clean "$(printf '%s' "$health" | json_get 'str(d.get("llm_model"))')")"
    printf 'model_digest=%s\n'          "$(fp_clean "$digest")"
    printf 'show_sha256=%s\n'           "$(fp_clean "$show")"
    printf 'llm_temperature=%s\n'       "$(fp_clean "$(printf '%s' "$health" | json_get 'str(d.get("llm_temperature"))')")"
    printf 'llm_seed=%s\n'              "$(fp_clean "$(printf '%s' "$health" | json_get 'str(d.get("llm_seed"))')")"
    printf 'llm_num_predict=%s\n'       "$(fp_clean "$np")"
    printf 'embedding_device=%s\n'      "$(fp_clean "$(printf '%s' "$health" | json_get 'str(d.get("embedding_device"))')")"
    printf 'gpu=%s\n'                   "$(fp_clean "$gpu")"
    printf 'driver=%s\n'                "$(fp_clean "$driver")"
    printf 'python=%s\n'                "$(fp_clean "$pyv")"
    printf 'torch=%s\n'                 "$(fp_clean "$tv")"
    printf 'sentence_transformers=%s\n' "$(fp_clean "$stv")"
    printf 'ollama_processor=-\n'       # 골든 첫 호출 직후 /api/ps 로 채운다 (지금은 모델이 내려가 있을 수 있다)
  } > "$out" 2>/dev/null || true
}

# ===========================================================
# backup — 소스에서 패키지 생성
# ===========================================================
baseline_partial() {  # baseline_partial <항목> — 기준선 중 빠진 항목 (BASELINE_STATUS=partial:<항목,...>)
  case ",$BL_PARTIAL," in
    *",$1,"*) ;;
    *) BL_PARTIAL="${BL_PARTIAL:+$BL_PARTIAL,}$1" ;;
  esac
}

golden_precheck() {  # GOLDEN=1 전제 — 결정적 생성 설정 · 앱 기동 · Ollama 응답 (스냅샷 전에 확인)
  local health temp seed code ver ok=1
  case "$GOLDEN_REPEAT" in ''|*[!0-9]*) die "GOLDEN_REPEAT 는 1 이상의 정수입니다: $GOLDEN_REPEAT" ;; esac
  # 10진수로 고정한다 — 08 · 09 는 셸 산술에서 8진수로 읽혀 골든 호출(수십 분)이 끝난 뒤에야 죽고, 00 은 0 이다
  GOLDEN_REPEAT="$(num "$GOLDEN_REPEAT")"
  [ "$GOLDEN_REPEAT" -ge 1 ] || die "GOLDEN_REPEAT 는 1 이상의 정수입니다: $GOLDEN_REPEAT"
  if [ -n "$GOLDEN_QUESTIONS_FILE" ] && [ ! -f "$GOLDEN_QUESTIONS_FILE" ]; then
    die "골든 질문 파일이 없습니다: $GOLDEN_QUESTIONS_FILE"
  fi
  health="$(ai_curl /health 2>/dev/null)" || health=""
  [ -n "$health" ] || die "AI 서버 /health 응답이 없습니다 — 골든 생성에는 앱이 떠 있어야 합니다"
  temp="$(printf '%s' "$health" | json_get 'd.get("llm_temperature")')"
  seed="$(printf '%s' "$health" | json_get 'd.get("llm_seed")')"
  # 생성 파라미터는 AI 서버 기동 때 한 번만 읽힌다 — 값을 바꿨으면 재기동해야 반영된다
  case "$temp" in 0|0.0) ;; *) ok=0 ;; esac
  if [ -z "$seed" ] || [ "$seed" = None ]; then ok=0; fi
  [ "$ok" = 1 ] || die "골든 생성 전제 불충족 — LLM_TEMPERATURE=0 LLM_SEED=42 로 AI 서버를 재기동하세요 (현재 temperature=${temp:-?} seed=${seed:-?})"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$FRONT/widget.js" 2>/dev/null)" || true
  [ "$code" = 200 ] || die "프론트엔드 $FRONT/widget.js 응답이 200 이 아닙니다 (${code:-없음}) — 골든은 위젯 경로(/api/chat)로 묻는다"
  ver="$( { ollama_curl /api/version 2>/dev/null | json_get 'd.get("version") or ""'; } )" || ver=""
  [ -n "$ver" ] || die "Ollama /api/version 응답이 없습니다 — 골든 생성에는 LLM 이 떠 있어야 합니다"
  log "골든 전제 확인 — temperature $temp · seed $seed · Ollama $ver · $FRONT"
}

backup_golden() {  # backup_golden <패키지디렉토리> <라이브 DB> — 골든 질문을 소스에 던져 golden.json 을 만든다
  local out="$1" db="$2" g="$WORK_TMP/golden" cc model before after expect got r i qid pre body gb rc=0 bad=0 f live_rc=0 note=""
  local fp="$out/fingerprint-source.txt"
  local -a qargs=() qs=()
  mkdir -p "$g/raw"

  # 1. 질문 — NFC · 앞뒤 공백 정리 (macOS 에서 편집한 파일은 NFD 일 수 있다). 타겟은 golden.json 의 문자열을 그대로 쓴다.
  [ -z "$GOLDEN_QUESTIONS_FILE" ] || qargs=(--file "$GOLDEN_QUESTIONS_FILE")
  mc golden-questions ${qargs[@]+"${qargs[@]}"} > "$g/questions.txt" || die "골든 질문을 읽지 못했습니다${GOLDEN_QUESTIONS_FILE:+: $GOLDEN_QUESTIONS_FILE}"
  mapfile -t qs < "$g/questions.txt"
  [ "${#qs[@]}" -gt 0 ] || die "골든 질문이 없습니다${GOLDEN_QUESTIONS_FILE:+: $GOLDEN_QUESTIONS_FILE}"

  # 2. clientCode — 지정값, 없으면 상품이 가장 많은 승인 업체 (동점은 client_code 순 — 매번 같은 업체)
  cc="$GOLDEN_CLIENT_CODE"
  if [ -z "$cc" ]; then
    cc="$(sqlite3 -readonly "$out/$DB_NAME" "SELECT c.client_code FROM company c JOIN product_item p ON p.company_id = c.id WHERE c.status = 'APPROVED' AND p.deleted_at IS NULL GROUP BY c.id ORDER BY count(*) DESC, c.client_code LIMIT 1;" 2>/dev/null)" || cc=""
  fi
  [ -n "$cc" ] || die "골든 clientCode 를 정하지 못했습니다 (상품이 있는 승인 업체 없음) — GOLDEN_CLIENT_CODE 로 지정하세요"
  model="$(llm_model_name)"
  log "   질문 ${#qs[@]}개 · clientCode $cc · 모델 $model"

  # 3. 골든 호출 전 라이브 chat_log 건수 — 호출마다 정확히 1행씩 늘어야 다른 요청이 섞이지 않은 것이다
  before="$(${DATA_SUDO} sqlite3 -readonly -cmd '.timeout 5000' "$db" 'SELECT count(*) FROM chat_log;' 2>/dev/null)" \
    || die "라이브 DB 의 chat_log 를 읽지 못했습니다: $db"

  # 4. 회차 × 문항 — L3(위젯 전체 경로) · L2(같은 상품 목록으로 생성만). 요청은 순차로만 보낸다
  #    (동시 요청은 Ollama 결과를 흔든다). 호출마다 모델을 내려 같은 콜드 조건을 만든다.
  for r in $(seq 1 "$GOLDEN_REPEAT"); do
    for i in "${!qs[@]}"; do
      qid="$(printf 'q%02d' "$((i + 1))")"
      pre="$g/raw/r$r-$qid"
      llm_unload "$model" || die "LLM 모델을 내리지 못했습니다 ($model — /api/ps 확인 · 위젯·브라우저 등 다른 요청이 모델을 다시 올리고 있을 수 있습니다 — 트래픽을 막고 다시)"
      front_chat "$cc" "${qs[$i]}" "$pre-l3"
      if [ "$r" = 1 ] && [ "$i" = 0 ]; then
        kv_set "$fp" ollama_processor "$(ollama_processor)"
      fi
      if body="$(mc l2-body --l3 "$pre-l3.json" --client-code "$cc" --question "${qs[$i]}" 2>/dev/null)" && [ -n "$body" ]; then
        llm_unload "$model" || die "LLM 모델을 내리지 못했습니다 ($model — /api/ps 확인 · 위젯·브라우저 등 다른 요청이 모델을 다시 올리고 있을 수 있습니다 — 트래픽을 막고 다시)"
        ai_generate "$body" "$pre-l2"
      else
        : > "$pre-l2.json"; printf '000' > "$pre-l2.code"     # L3 가 무효라 같은 상품 목록을 만들 수 없다
      fi
      log "   r$r $qid — L3 $(cat "$pre-l3.code") · L2 $(cat "$pre-l2.code")"
    done
  done

  # 5. 다른 요청이 섞이지 않았는지 — chat_log 증가분 = 회차 × 문항
  after="$(${DATA_SUDO} sqlite3 -readonly -cmd '.timeout 5000' "$db" 'SELECT count(*) FROM chat_log;' 2>/dev/null)" \
    || die "라이브 DB 의 chat_log 를 읽지 못했습니다: $db"
  expect=$((GOLDEN_REPEAT * ${#qs[@]}))
  got=$(( $(num "$after") - $(num "$before") ))
  if [ "$got" != "$expect" ]; then
    # 응답이 실패한 호출은 chat_log 를 남기지 않을 수 있다 — 원인 짚기용으로 같이 적는다
    for f in "$g"/raw/*-l3.code; do [ "$(cat "$f")" = 200 ] || bad=$((bad + 1)); done
    [ "$bad" = 0 ] || note=" · L3 HTTP 200 아님 ${bad}건"
    die "골든 생성 중 다른 요청이 들어왔습니다(chat_log +$expect/+$got$note) — 위젯·브라우저 트래픽을 막고 다시"
  fi

  # 6. 소스 불변 — 골든 호출 전후로 chat_log 밖의 DB · 색인이 그대로여야 골든이 패키지와 같은 데이터에서 나온 것이다.
  #    --exclude-table chat_log 는 _schema 에서도 chat_log 객체를 빼므로 패키지 DB 도 같은 옵션으로 다시 계산해 비교한다.
  log "   소스 불변 확인 (chat_log 제외 DB · 색인)"
  mc db-hash "$out/$DB_NAME" --base "$STORAGE_BASE" --immutable --exclude-table chat_log > "$g/db-package.tsv" \
    || die "패키지 DB 해시 계산 실패 (migcheck db-hash)"
  ${DATA_SUDO} python3 "$MIGCHECK" db-hash "$db" --base "$STORAGE_BASE" --exclude-table chat_log > "$g/db-live.tsv" || live_rc=$?
  if [ "$RUNTIME" = compose ]; then   # root 로 열었으니 -wal/-shm 소유자를 backend 로 되돌린다
    ${DATA_SUDO} chown "$DATA_OWNER" "$db-wal" "$db-shm" 2>/dev/null || true
  fi
  [ "$live_rc" = 0 ] || die "라이브 DB 해시 계산 실패 (migcheck db-hash): $db"
  if ! cmp -s "$g/db-package.tsv" "$g/db-live.tsv"; then
    diff "$g/db-package.tsv" "$g/db-live.tsv" >&2 || true
    die "골든 생성 중 소스 데이터가 바뀌었습니다 — 쓰기를 멈추고 다시 (DB — 위 diff 좌: 패키지 / 우: 라이브)"
  fi
  if [ -f "$out/baseline-rag.tsv" ]; then
    rag_hash_all "$g/rag.tsv" "$g/rag-docs.tsv" || die "색인 해시 재계산 실패 — 골든 생성 중 소스 불변을 확인할 수 없습니다"
    if ! cmp -s "$g/rag.tsv" "$out/baseline-rag.tsv"; then
      diff "$out/baseline-rag.tsv" "$g/rag.tsv" >&2 || true
      die "골든 생성 중 소스 데이터가 바뀌었습니다 — 쓰기를 멈추고 다시 (색인 — 위 diff 좌: 기준선 / 우: 지금)"
    fi
  else
    warn "   색인 불변 확인 건너뜀 (BASELINE_RAG=0)"
  fi

  # 7. golden.json — 판정(유효 · L2=L3 · 회차 간 안정)은 migcheck 가 한다. 실패여도 진단용으로 파일은 남는다.
  gb="$(mc golden-build --questions "$g/questions.txt" --client-code "$cc" --raw-dir "$g/raw" \
        --meta "$fp" --repeat "$GOLDEN_REPEAT" --out "$out/golden.json")" || rc=$?
  GOLDEN_STATUS="$(line_value "$gb" GOLDEN_STATUS)"; GOLDEN_STATUS="${GOLDEN_STATUS:-failed:internal}"
  GOLDEN_ITEMS="$(num "$(line_value "$gb" GOLDEN_ITEMS)")"
  [ "$rc" = 0 ] || die "골든 기준 불완전: $GOLDEN_STATUS — $out/golden.json 확인"
  log "   골든 $GOLDEN_STATUS — ${GOLDEN_ITEMS}문항 (GPU 적재 $(kv_get "$fp" ollama_processor))"
}

cmd_backup() {
  local ts out
  ts="$(date +%Y%m%d%H%M%S)"
  out="${1:-$HOME/widgetrag-backup/$(date +%Y%m%d-%H%M)}"
  setup_runtime
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI 필요 — sudo apt-get install -y sqlite3"

  # 이관 동등성 기준선 · 골든 설정
  BASELINE="${BASELINE:-1}"; BASELINE_RAG="${BASELINE_RAG:-1}"
  GOLDEN="${GOLDEN:-0}"; GOLDEN_REPEAT="${GOLDEN_REPEAT:-2}"
  GOLDEN_QUESTIONS_FILE="${GOLDEN_QUESTIONS_FILE:-}"; GOLDEN_CLIENT_CODE="${GOLDEN_CLIENT_CODE:-}"
  BASELINE_STATUS="off"; BL_PARTIAL=""; CHATLOG_MAX_ID=""; SOURCE_SERVICES=""; SOURCE_SERVICE_COUNT=""
  GOLDEN_STATUS="skipped:off"; GOLDEN_ITEMS=0
  if [ "$GOLDEN" = 1 ] && [ "$BASELINE" != 1 ]; then
    die "GOLDEN=1 은 BASELINE=1 이 필요합니다 (골든 생성 중 소스 불변 확인에 DB 기준선을 쓴다)"
  fi
  # package-files.tsv 는 BASELINE=0 이어도 항상 기록한다 (FORMAT 2 — fetch 의 전수 대조) → migcheck 는 늘 필요
  need_migcheck
  if [ "$GOLDEN" = 1 ]; then
    golden_precheck      # 스냅샷(수 분) 전에 빨리 실패한다
  fi

  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    die "출력 디렉토리가 비어 있지 않습니다: $out"
  fi
  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
  WORK_TMP="$(mktemp -d)"
  trap cleanup_tmp EXIT

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

  # 이관 동등성 기준선 — 색인 내용 해시를 스냅샷 직전 · 직후에 떠서 둘이 같을 때만 기록한다.
  # backup 은 서비스를 멈추지 않으므로(비원자적) 그 사이 색인이 바뀌면 스냅샷과 해시가 어긋날 수 있다.
  local rag_pre=0
  if [ "$BASELINE" = 1 ] && [ "$BASELINE_RAG" = 1 ]; then
    log "   색인 내용 해시 — 스냅샷 직전"
    if rag_hash_all "$WORK_TMP/rag-pre.tsv" "$WORK_TMP/rag-pre-docs.tsv"; then
      rag_pre=1
    else
      warn "   색인 내용 해시 실패 — RAG 기준선 없이 계속합니다 (타겟은 문서 수만 대조)"
      baseline_partial rag
    fi
  fi

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
  if [ "$rag_pre" = 1 ]; then
    log "   색인 내용 해시 — 스냅샷 직후"
    if ! rag_hash_all "$WORK_TMP/rag-post.tsv" "$WORK_TMP/rag-post-docs.tsv"; then
      warn "   색인 내용 해시 실패 — RAG 기준선 없이 계속합니다 (타겟은 문서 수만 대조)"
      baseline_partial rag
    elif ! cmp -s "$WORK_TMP/rag-pre.tsv" "$WORK_TMP/rag-post.tsv" \
         || ! cmp -s "$WORK_TMP/rag-pre-docs.tsv" "$WORK_TMP/rag-post-docs.tsv"; then
      warn "   스냅샷 도중 색인이 바뀌었습니다 — 쓰기를 멈추고 다시 뜨세요 (RAG 기준선 기록 안 함)"
      baseline_partial rag
    elif [ "$(awk -F'\t' 'index($1, "#") == 0 {print $1 "\t" $2}' "$WORK_TMP/rag-post.tsv")" != "$(cat "$out/doccount.tsv")" ]; then
      # 해시로 센 문서 수가 _cat/indices 와 다르면 스냅샷 뒤에 색인이 바뀐 것이다
      warn "   색인 해시의 문서 수가 doccount.tsv 와 다릅니다 — 쓰기를 멈추고 다시 뜨세요 (RAG 기준선 기록 안 함)"
      baseline_partial rag
    else
      cp "$WORK_TMP/rag-post.tsv" "$out/baseline-rag.tsv"
      cp "$WORK_TMP/rag-post-docs.tsv" "$out/baseline-rag-docs.tsv"
      log "   RAG 기준선: 인덱스 $(awk -F'\t' 'index($1, "#") == 0 {n++} END {print n + 0}' "$out/baseline-rag.tsv")개 — 스냅샷 전후 일치"
    fi
  elif [ "$BASELINE" = 1 ] && [ "$BASELINE_RAG" != 1 ]; then
    log "   색인 내용 해시 — 건너뜀 (BASELINE_RAG=0)"
    baseline_partial rag-off
  fi
  # 색인 기준선 없이는 골든이 패키지 색인에서 나왔는지(골든 6단계) 확인할 수 없다 — 아카이브(수 분) 전에 멈춘다
  if [ "$GOLDEN" = 1 ] && [ "$BASELINE_RAG" = 1 ] && [ ! -f "$out/baseline-rag.tsv" ]; then
    die "색인 기준선이 없어(partial:rag) 골든 생성 중 소스 불변을 확인할 수 없습니다 — 쓰기를 멈추고 다시 뜨세요"
  fi
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
  if [ "$BASELINE" = 1 ]; then
    # 이관 동등성 기준선 — 테이블별 논리 해시. 패키지 DB 는 immutable 로 읽기만 한다 (고치면 체크섬이
    # 바뀐다). chat_log 는 이 시점의 MAX(id) 로 잘라 두어, 타겟에서 verify 챗 · 골든 호출로 늘어난
    # 행을 빼고 비교한다 (id 는 IDENTITY 라 새 행은 항상 max+1).
    mc db-hash "$out/$DB_NAME" --base "$STORAGE_BASE" --immutable --info "$WORK_TMP/db-info.txt" >/dev/null \
      || die "DB 기준선 계산 실패 (migcheck db-hash) — 기준선 없이 뜨려면 BASELINE=0"
    CHATLOG_MAX_ID="$(kv_get "$WORK_TMP/db-info.txt" chat_log_max_id)"
    [ -n "$CHATLOG_MAX_ID" ] || die "DB 기준선 계산 실패 — chat_log_max_id 를 얻지 못했습니다"
    mc db-hash "$out/$DB_NAME" --base "$STORAGE_BASE" --immutable --chatlog-max-id "$CHATLOG_MAX_ID" \
      > "$out/baseline-db.tsv" || die "DB 기준선 계산 실패 (migcheck db-hash) — 기준선 없이 뜨려면 BASELINE=0"
    log "   DB 기준선: 테이블 $(awk -F'\t' '$1 != "_schema" {n++} END {print n + 0}' "$out/baseline-db.tsv")개 · chat_log id ≤ $CHATLOG_MAX_ID"
  fi

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

  # ----- 4. 이관 동등성 기준선 (서비스 · 환경 지문) -----
  if [ "$BASELINE" = 1 ]; then
    log "4. 이관 동등성 기준선"
    local svc
    svc="$(list_services | mc services --runtime "$RUNTIME")" || svc=""
    SOURCE_SERVICE_COUNT="$(line_value "$svc" SERVICE_COUNT)"
    SOURCE_SERVICES="$(line_value "$svc" SERVICES)"
    if [ "$(num "$SOURCE_SERVICE_COUNT")" = 0 ]; then
      # 0개로 적으면 타겟이 "소스 0개"와 대조해 FAIL 이 난다 — 비워 두어 "기준선 없음"으로 보이게 한다
      warn "   실행 중인 서비스를 읽지 못했습니다 — 타겟 T1-1 은 기준선 없음으로 끝납니다"
      SOURCE_SERVICE_COUNT=""; SOURCE_SERVICES=""
      baseline_partial services
    else
      log "   서비스 ${SOURCE_SERVICE_COUNT}개 — $SOURCE_SERVICES"
    fi
    fingerprint "$out/fingerprint-source.txt" || true
    log "   지문: Ollama $(kv_get "$out/fingerprint-source.txt" ollama_version) · $(kv_get "$out/fingerprint-source.txt" llm_model)" \
        "· temperature $(kv_get "$out/fingerprint-source.txt" llm_temperature) · seed $(kv_get "$out/fingerprint-source.txt" llm_seed)" \
        "· GPU $(kv_get "$out/fingerprint-source.txt" gpu)"
    if [ -z "$BL_PARTIAL" ]; then BASELINE_STATUS="ok"; else BASELINE_STATUS="partial:$BL_PARTIAL"; fi
  else
    log "4. 이관 동등성 기준선 — 건너뜀 (BASELINE=0)"
  fi

  # ----- 5. 골든 응답 (테스트2 기준) -----
  # VACUUM INTO 뒤에 한다 — 골든 호출은 chat_log 에 행을 더하지만 패키지 DB 는 이미 떠 두었으므로
  # 패키지 내용이 골든 실행 여부와 무관하다.
  if [ "$GOLDEN" = 1 ]; then
    log "5. 골든 응답 (${GOLDEN_REPEAT}회 반복 · 호출마다 모델을 내려 콜드 로드)"
    backup_golden "$out" "$db"
  fi

  # ----- 6. 메타데이터 · 체크섬 -----
  log "6. 매니페스트 · 체크섬"
  local os_ver
  os_ver="$(os_curl "$OS" | py 'd["version"]["number"]' 2>/dev/null || echo unknown)"
  # 패키지 지문 사슬: checksums.sha256 ⊃ package.env ∋ PACKAGE_FILES_SHA256 = sha256(package-files.tsv) ⊃ 파일마다 해시.
  # checksums.sha256 은 기존 5종 그대로 둔다 — 구형 fetch 는 새 파일을 받지 않으므로, 여기에 넣으면 -c 가 깨진다.
  mc inventory "$out" --exclude package-files.tsv --exclude package.env --exclude checksums.sha256 --exclude MANIFEST.txt \
    > "$out/package-files.tsv" || die "패키지 파일 목록(package-files.tsv)을 만들지 못했습니다 (migcheck inventory)"
  local pf_sha pf_n pf_b
  pf_sha="$(sha256sum "$out/package-files.tsv" | cut -d' ' -f1)"
  pf_n="$(awk 'END {print NR}' "$out/package-files.tsv")"
  pf_b="$(awk -F'\t' '{s += $2} END {printf "%.0f\n", s}' "$out/package-files.tsv")"
  cat > "$out/package.env" <<EOF
PACKAGE_FORMAT=2
CREATED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
SOURCE_HOST=$(hostname)
SOURCE_RUNTIME=$RUNTIME
SOURCE_STORAGE_BASE=$STORAGE_BASE
SNAPSHOT_NAME=$snap
OPENSEARCH_VERSION=$os_ver
SOURCE_FORM=$SOURCE_FORM_NAME
SOURCE_SERVICES=$SOURCE_SERVICES
SOURCE_SERVICE_COUNT=$SOURCE_SERVICE_COUNT
CHATLOG_MAX_ID=$CHATLOG_MAX_ID
BASELINE_STATUS=$BASELINE_STATUS
GOLDEN_STATUS=$GOLDEN_STATUS
GOLDEN_ITEMS=$GOLDEN_ITEMS
PACKAGE_FILES_SHA256=$pf_sha
PACKAGE_FILES_COUNT=$pf_n
PACKAGE_FILES_BYTES=$pf_b
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
  package-files.tsv            패키지 파일 전부의 바이트 · SHA-256 (아래 기준선 파일 포함)

정합성 확인
  전송 직후   sha256sum -c checksums.sha256
              package.sh fetch 가 package-files.tsv 의 파일을 전부 받아 바이트 · 해시를 대조한다
  복원 직후   package.sh restore 가 풀린 파일의 개수 · 총 용량 · 해시를 대조한다
              (목록 파일 contents.tsv 가 두 아카이브 안에 함께 들어 있다)

이관 동등성 기준선 (타겟: verify.sh COMPARE=1 → package.sh compare)
  기준선      $BASELINE_STATUS
  골든 응답   $GOLDEN_STATUS (${GOLDEN_ITEMS}문항)
  패키지 지문 $pf_sha
              = package-files.tsv 의 SHA-256 — 파일 ${pf_n}개 · ${pf_b} bytes
$(awk -F'\t' '{printf "    %-30s %15s bytes  %s\n", $1, $2, substr($3, 1, 12)}' "$out/package-files.tsv")

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
  log "패키지 지문 ${pf_sha:0:12} — 파일 ${pf_n}개 · ${pf_b} bytes (기준선 $BASELINE_STATUS · 골든 $GOLDEN_STATUS)"

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
  local uri="${1:-}" dir="${2:-$HOME/widgetrag-package}" f fmt want have name
  [ -n "$uri" ] || die "사용법: $0 fetch <URI> [받을디렉토리]"
  uri="${uri%/}"
  mkdir -p "$dir"
  # 원본이 받을 디렉토리 자신(로컬 경로 · 심볼릭 링크 포함)이면 아래에서 패키지 파일을 지운 뒤 빈 곳에서
  # 복사하게 된다 — 패키지가 통째로 사라지므로 아무것도 지우기 전에 멈춘다
  if [ -d "$uri" ] && [ "$(cd "$uri" && pwd -P)" = "$(cd "$dir" && pwd -P)" ]; then
    die "원본과 받을 디렉토리가 같습니다: $dir — 이미 받아둔 패키지는 SNAPSHOT_URI 없이 복원하세요"
  fi

  # 같은 곳에서 이미 받아 온전하면 다시 받지 않는다 (재부팅 후 재개 · 재실행)
  if [ "$(cat "$dir/.source" 2>/dev/null)" = "$uri" ] \
     && ( cd "$dir" && sha256sum -c --quiet checksums.sha256 ) >/dev/null 2>&1 \
     && verify_pkg_files "$dir"; then
    log "이미 받은 패키지 — 체크섬 일치, 다시 받지 않습니다: $dir"
    return 0
  fi

  rm -f "$dir/.source" "$dir/.restored"
  # 이전 패키지 파일을 먼저 지운다 — 다른(구형) 패키지의 기준선 파일이 남아 있으면 compare 가
  # 그것을 이 패키지의 기준선으로 오인한다. .restore-state 도 이 패키지의 복원 기록이 아니게 된다.
  for f in "${PKG_FILES[@]}" package-files.tsv golden.json fingerprint-source.txt .restore-state; do
    rm -f "${dir:?}/$f"
  done
  rm -f "${dir:?}"/baseline-*.tsv
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

  # FORMAT 2 — 기준선 파일은 5종 체크섬 밖에 있다. package.env(체크섬 통과)의 지문으로 목록을 확인하고,
  # 목록의 파일을 모두 받아 바이트 · 해시를 대조한다 (하나라도 빠지면 이관 동등성 비교가 성립하지 않는다).
  fmt="$(num "$(pkg_value "$dir" PACKAGE_FORMAT)")"
  if [ "$fmt" -ge 2 ]; then
    fetch_one "$uri/package-files.tsv" "$dir/package-files.tsv" || die "받지 못했습니다: $uri/package-files.tsv"
    want="$(pkg_value "$dir" PACKAGE_FILES_SHA256)"
    have="$(sha256sum "$dir/package-files.tsv" | cut -d' ' -f1)"
    [ -n "$want" ] && [ "$have" = "$want" ] \
      || die "패키지 파일 목록 불일치 — package-files.tsv 의 SHA-256 이 package.env 와 다릅니다 ($dir)"
    while IFS=$'\t' read -r name _; do
      [ -n "$name" ] || continue
      pkg_name_ok "$name" || die "패키지 파일 목록에 쓸 수 없는 이름이 있습니다: $name"
      [ -e "$dir/$name" ] && continue
      fetch_one "$uri/$name" "$dir/$name" </dev/null || die "받지 못했습니다: $uri/$name"
    done < "$dir/package-files.tsv"
    verify_pkg_files "$dir" || die "패키지 파일 불일치: $PKG_BAD"
  fi

  echo "$uri" > "$dir/.source"
  log "체크섬 확인 — $(du -sh "$dir" | cut -f1) (원본 $(pkg_value "$dir" SOURCE_HOST) · $(pkg_value "$dir" SOURCE_RUNTIME))"
  if [ "$fmt" -ge 2 ]; then
    log "패키지 파일 대조 — $(pkg_value "$dir" PACKAGE_FILES_COUNT)개 일치 · 지문 ${have:0:12} (기준선 $(pkg_value "$dir" BASELINE_STATUS) · 골든 $(pkg_value "$dir" GOLDEN_STATUS))"
  fi
}

# ===========================================================
# restore — 타겟에 색인 · DB · 업로드 파일 복원
#   앱(backend)이 뜨기 전에 부른다 — backend 는 기동할 때 색인이 없으면 빈 색인을 만들고,
#   DB 가 없으면 빈 DB 와 관리자 계정을 만든다.
# ===========================================================
restore_index() {
  local pkg="$1" idx have has_docs=0 imp_host snap indices resp mode
  log "색인 복원 ($RUNTIME)"
  ensure_repo_path

  while IFS=$'\t' read -r idx _; do
    [ -n "$idx" ] || continue
    have="$( { os_curl "$OS/$idx/_count" 2>/dev/null | py 'd.get("count", "")' 2>/dev/null; } || true )"
    if [ -n "$have" ] && [ "$have" -gt 0 ] 2>/dev/null; then has_docs=1; fi
  done < "$pkg/doccount.tsv"
  if [ "$has_docs" = 1 ] && [ "${FORCE_RESTORE:-0}" != 1 ]; then
    log "   색인이 이미 있습니다 — 복원 건너뜀 (덮어쓰려면 FORCE_RESTORE=1)"
    IDX_STATE=skipped
    return 0
  fi
  # .restore-state 용 — 문서가 있는 색인을 FORCE_RESTORE=1 로 덮으면 forced, 없던 것을 채우면 restored
  if [ "$has_docs" = 1 ]; then mode=forced; else mode=restored; fi

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
      IDX_STATE="$mode"; RESTORED_SNAPSHOT="$snap"
      return 0
    fi
    sleep 3
  done
  diff <(cat "$pkg/doccount.tsv") <(doc_counts) || true
  die "문서 수 불일치 — 위 diff 확인 (좌: 소스 / 우: 타겟)"
}

restore_data() {
  local pkg="$1" dir db tmp from ts mode=restored
  log "DB · 업로드 파일 복원 ($RUNTIME)"
  dir="$(data_dir)"
  db="$dir/$DB_NAME"

  if ${DATA_SUDO} test -f "$db"; then
    if [ "${FORCE_RESTORE:-0}" != 1 ]; then
      log "   DB 가 이미 있습니다 — 복원 건너뜀 (덮어쓰려면 FORCE_RESTORE=1)"
      DATA_STATE=skipped
      return 0
    fi
    mode=forced
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
  DATA_STATE="$mode"
}

write_restore_state() {  # write_restore_state <패키지디렉토리> — 이번에 한 일을 .restore-state 에 병합 (compare 가 보고에 싣는다)
  # 부분 복원(index 만 · data 만)도 있으므로 이번에 다루지 않은 키는 기존 값을 그대로 둔다.
  local st="$1/.restore-state"
  if [ -n "$IDX_STATE" ]; then kv_set "$st" index "$IDX_STATE"; fi
  if [ -n "$DATA_STATE" ]; then kv_set "$st" data "$DATA_STATE"; fi
  if [ -n "$RESTORED_SNAPSHOT" ]; then kv_set "$st" snapshot "$RESTORED_SNAPSHOT"; fi
  kv_set "$st" at "$(date '+%Y-%m-%d %H:%M:%S')"
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
  write_restore_state "$pkg"
  log "복원 단계 완료 ($what, $(( $(date +%s) - started ))초)"
}

# ===========================================================
# compare — 타겟에서 이관 동등성 비교 (복원 · 앱 기동 뒤 — verify.sh COMPARE=1 이 부른다)
#   ROW(test · item · source · target · result · note, 탭 구분 6열)는 stdout 으로만, 진행 로그는
#   stderr 로 낸다. 불일치로는 die 하지 않는다 — 단계마다 실패를 받아 ROW 로 남기고 다음으로 간다
#   (사용법 오류만 die). FAIL ROW 가 하나라도 있으면 종료코드 1.
#   순서: T1-1 서비스 → T1-2 패키지 → T1-3 DB · RAG · 업로드 → T2 골든 (T2 가 chat_log 를 늘리므로 DB 뒤)
#   진행 단계는 <증적>/.compare-stage 에 적고 끝까지 돌면 done — verify.sh 가 중간 종료를 FAIL 로 잡는다.
# ===========================================================
row() {  # row <test> <item> <source> <target> <result> <note> — ROW 한 줄 (탭 · 개행은 공백, 빈 값은 -)
  local f line="" sep=""
  for f in "$@"; do
    f="${f//$'\t'/ }"; f="${f//$'\r'/ }"; f="${f//$'\n'/ }"
    line="$line$sep${f:--}"; sep=$'\t'
  done
  printf '%s\n' "$line" >> "$CMP_ROWS"
  printf '%s\n' "$line" >&3
}

mc_rows() {  # mc_rows <출력파일> <migcheck 인자...> — migcheck 가 낸 ROW 를 그대로 내보낸다 (종료코드 0 · 1=FAIL 있음 · 2=오류)
  local o="$1" rc=0
  shift
  mc "$@" > "$o" || rc=$?
  cat "$o" >> "$CMP_ROWS" 2>/dev/null || true
  cat "$o" >&3 2>/dev/null || true
  return "$rc"
}

mc_err() {  # mc_err <종료코드> <test> <item> <도구> — migcheck 비교류의 2 이상(사용법 · 내부 오류)을 FAIL ROW 로
  [ "$1" -le 1 ] || row "$2" "$3" - - FAIL "비교 도구 오류 (migcheck $4 종료코드 $1)"
}

cmp_stage() {  # cmp_stage <증적디렉토리> <start|T1-1|T1-2|T1-3|T2|done> — 지금 도는 단계를 <증적>/.compare-stage 에 적는다
  # 중간에 끝난 비교(타임아웃 · OOM · 예기치 못한 오류)는 그때까지 낸 ROW 만 남아 PASS 로 보일 수 있다.
  # verify.sh 는 이 값이 done 이 아니면 멈춘 단계에 FAIL 을 붙인다 (종료코드만으로는 "FAIL 있음" 과 못 가른다).
  { printf '%s\n' "$2" > "$1/.compare-stage"; } 2>/dev/null || true
}

svc_roles() {  # svc_roles <role:name,...> — 역할만 정렬해 쉼표로 (모르는 서비스는 extra:<이름>)
  { printf '%s\n' "$1" | tr ',' '\n' | awk -F: 'NF == 0 {next} $1 == "extra" {print "extra:" $2; next} {print $1}' \
      | LC_ALL=C sort -u | paste -sd, - ; } 2>/dev/null || true
}
set_minus() {  # set_minus <a,b,...> <a,...> — 앞 목록에만 있는 항목 (쉼표로)
  { LC_ALL=C comm -23 <(printf '%s\n' "$1" | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort -u) \
                      <(printf '%s\n' "$2" | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort -u) | paste -sd, - ; } 2>/dev/null || true
}

cmp_services() {  # T1-1 — 실행 중인 서비스 수 · 역할 집합 (역할 매핑은 migcheck 한 곳에 — 교차 형태도 역할로 대조)
  local pkg="$1" evi="$2" out tn troles sn sroles src_form note="" miss extra res
  out="$(list_services | mc services --runtime "$RUNTIME" 2>/dev/null)" || out=""
  printf '%s\n' "$out" > "$evi/services-target.txt"
  tn="$(line_value "$out" SERVICE_COUNT)"
  troles="$(svc_roles "$(line_value "$out" SERVICES)")"
  sn="$(pkg_value "$pkg" SOURCE_SERVICE_COUNT)"
  sroles="$(svc_roles "$(pkg_value "$pkg" SOURCE_SERVICES)")"
  src_form="$(pkg_value "$pkg" SOURCE_FORM)"
  if [ -n "$src_form" ] && [ "$src_form" != "$SOURCE_FORM_NAME" ]; then
    note="교차 형태 역할 매핑 ($src_form → $SOURCE_FORM_NAME)"
  fi
  if [ -z "$tn" ]; then
    row T1-1 service_count "${sn:+$sn($sroles)}" - FAIL "타겟 서비스 목록을 읽지 못했습니다 (migcheck services)"
    return 0
  fi
  if [ -n "$sn" ]; then
    miss="$(set_minus "$sroles" "$troles")"; extra="$(set_minus "$troles" "$sroles")"
    if [ "$sn" = "$tn" ] && [ -z "$miss" ] && [ -z "$extra" ]; then
      res=PASS
    else
      res=FAIL
      note="${miss:+빠진 역할 $miss}${miss:+${extra:+ · }}${extra:+남는 역할 $extra}${note:+ · $note}"
      [ -n "$miss$extra" ] || note="서비스 수 다름${note:+ · $note}"
    fi
    row T1-1 service_count "$sn($sroles)" "$tn($troles)" "$res" "$note"
  elif [ -n "${EXPECT_SERVICE_COUNT:-}" ]; then
    if [ "$EXPECT_SERVICE_COUNT" = "$tn" ]; then res=PASS; else res=FAIL; fi
    row T1-1 service_count "$EXPECT_SERVICE_COUNT(EXPECT_SERVICE_COUNT)" "$tn($troles)" "$res" \
      "기준선 없음 — EXPECT_SERVICE_COUNT 와 수만 대조${note:+ · $note}"
  else
    row T1-1 service_count - "$tn($troles)" FAIL "기준선 없음 — 테스트 미수행"
  fi
}

cmp_package() {  # T1-2 — 패키지 파일 용량 · 해시 (restore 는 패키지 파일을 고치지 않는다 — DB 도 임시 복사본에 쓴다)
  local pkg="$1" evi="$2" fmt="$3" names want have res note rc
  names="$( { sed -E 's/^[0-9a-f]{64} [ *]//' "$pkg/checksums.sha256" | LC_ALL=C sort | paste -sd' ' - ; } 2>/dev/null )" || names=""
  if [ "$names" != "doccount.tsv opensearch-snapshots.tar.gz package.env uploads.tar.gz $DB_NAME" ]; then
    row T1-2 checksums "5종" "${names:-없음}" FAIL "checksums.sha256 목록이 5종이 아닙니다"
  elif ( cd "$pkg" && sha256sum -c --quiet checksums.sha256 ) >/dev/null 2>&1; then
    row T1-2 checksums "5종" "5종 일치" PASS "sha256sum -c checksums.sha256"
  else
    row T1-2 checksums "5종" "불일치" FAIL "sha256sum -c 실패 — 패키지 파일이 바뀌었거나 손상"
  fi

  if [ "$fmt" -lt 2 ]; then
    row T1-2 package-files - - FAIL "기준선 없음 — 테스트 미수행"
    return 0
  fi
  want="$(pkg_value "$pkg" PACKAGE_FILES_SHA256)"
  have="$( { sha256sum "$pkg/package-files.tsv" | cut -d' ' -f1; } 2>/dev/null )" || have=""
  if [ -n "$want" ] && [ "$have" = "$want" ]; then
    res=PASS; note="패키지 지문 = package.env PACKAGE_FILES_SHA256"
  else
    res=FAIL; note="package-files.tsv 가 없거나 package.env 의 지문과 다릅니다"
  fi
  row T1-2 package-files "${want:0:12}" "${have:0:12}" "$res" "$note"
  [ -f "$pkg/package-files.tsv" ] || return 0
  if mc inventory "$pkg" --exclude package-files.tsv --exclude package.env --exclude checksums.sha256 --exclude MANIFEST.txt \
       > "$evi/package-files-target.tsv" 2>/dev/null; then
    rc=0
    mc_rows "$CMP_TMP/rows-files.tsv" compare-tsv --test T1-2 --prefix file: --source "$pkg/package-files.tsv" \
      --target "$evi/package-files-target.tsv" --bytes-col 2 || rc=$?
    mc_err "$rc" T1-2 file: compare-tsv
  else
    row T1-2 file: - - FAIL "패키지 파일 목록을 만들지 못했습니다 (migcheck inventory)"
  fi
}

cmp_db() {  # T1-3 DB — 소스 기준선(S) = 패키지 DB 재계산(P) = 타겟 라이브 DB(T)
  local pkg="$1" evi="$2" cut src_base dir db rc t_rc=0 sp_p sp_t total kept pb tb
  local -a pcut=() tcut=()
  # 소스 경로 접두사 — 없으면(아주 옛 패키지) restore 도 재작성을 건너뛰었으므로 타겟 경로로 둬야 양쪽이 같게 남는다
  src_base="$(pkg_value "$pkg" SOURCE_STORAGE_BASE)"; src_base="${src_base:-$STORAGE_BASE}"
  cut="$(pkg_value "$pkg" CHATLOG_MAX_ID)"
  case "$cut" in *[!0-9]*) cut="" ;; esac
  [ -z "$cut" ] || pcut=(--chatlog-max-id "$cut")
  # P — 패키지 파일은 immutable 로 읽기만 (고치면 fetch 재사용 판정 · 체크섬이 깨진다). 컷이 없으면 전체 = MAX(id) 컷
  if ! mc db-hash "$pkg/$DB_NAME" --base "$src_base" --immutable ${pcut[@]+"${pcut[@]}"} --info "$evi/db-package-info.txt" \
       > "$evi/db-package.tsv"; then
    row T1-3 db - - FAIL "패키지 DB 해시 계산 실패 ($pkg/$DB_NAME)"
    return 0
  fi
  [ -n "$cut" ] || cut="$(num "$(kv_get "$evi/db-package-info.txt" chat_log_max_id)")"
  tcut=(--chatlog-max-id "$cut")

  if [ -f "$pkg/baseline-db.tsv" ]; then   # 소스 기준선 = 패키지 파일 (정상이면 나올 수 없는 차이 — 도구 · 버전 차이나 변조)
    rc=0
    mc_rows "$CMP_TMP/rows-db-package.tsv" compare-tsv --test T1-3 --prefix db-package: --source "$pkg/baseline-db.tsv" \
      --target "$evi/db-package.tsv" --bytes-col 3 --summary-only-if-pass || rc=$?
    mc_err "$rc" T1-3 db-package: compare-tsv
  else
    row T1-3 db:baseline - - INFO "기준선 없음 — 패키지 DB 재계산으로 대조"
  fi

  dir="$(data_dir)" || dir=""
  if [ -z "$dir" ]; then
    row T1-3 db - - FAIL "타겟 데이터 디렉토리를 찾지 못했습니다"
    return 0
  fi
  db="$dir/$DB_NAME"
  # T — 라이브 DB (WAL) 는 mode=ro 로. compose 는 root 로 읽으므로 info 는 임시 디렉토리에 받고 내용만 옮긴다
  ${DATA_SUDO} python3 "$MIGCHECK" db-hash "$db" --base "$STORAGE_BASE" "${tcut[@]}" --info "$CMP_TMP/db-target-info.txt" \
    > "$evi/db-target.tsv" || t_rc=$?
  ${DATA_SUDO} cat "$CMP_TMP/db-target-info.txt" > "$evi/db-target-info.txt" 2>/dev/null || true
  if [ "$RUNTIME" = compose ]; then   # root 로 열었으니 -wal/-shm 소유자를 backend 로 되돌린다
    ${DATA_SUDO} chown "$DATA_OWNER" "$db-wal" "$db-shm" 2>/dev/null || true
  fi
  if [ "$t_rc" = 0 ]; then
    rc=0
    mc_rows "$CMP_TMP/rows-db.tsv" compare-tsv --test T1-3 --prefix db: --source "$evi/db-package.tsv" \
      --target "$evi/db-target.tsv" --bytes-col 3 || rc=$?
    mc_err "$rc" T1-3 db: compare-tsv
  else
    row T1-3 db - - FAIL "타겟 DB 해시 계산 실패 ($db)"
  fi

  # 판정 제외 정보 — 의도된 차이 · 설계상 다른 값
  sp_p="$(kv_get "$evi/db-package-info.txt" storage_path_prefixed)"
  sp_t="$(kv_get "$evi/db-target-info.txt" storage_path_prefixed)"
  row T1-3 db:storage_path_rewrite "$src_base · ${sp_p:-?}건" "$STORAGE_BASE · ${sp_t:-?}건" INFO "의도된 차이 — 정규화 후 비교"
  total="$(kv_get "$evi/db-target-info.txt" chat_log_total)"
  kept="$( { awk -F'\t' '$1 == "chat_log" {print $2}' "$evi/db-target.tsv"; } 2>/dev/null )" || kept=""
  if [ -n "$total" ] && [ -n "$kept" ]; then
    row T1-3 db:chat_log_after_migration "id ≤ $cut" "+$(( $(num "$total") - $(num "$kept") ))건 (전체 ${total}건)" INFO \
      "이관 뒤 추가된 대화 기록 — 비교에서 제외 (verify 챗 · 골든 호출)"
  else
    row T1-3 db:chat_log_after_migration "id ≤ $cut" unavailable INFO "타겟 chat_log 건수를 읽지 못했습니다"
  fi
  pb="$(stat -c %s "$pkg/$DB_NAME" 2>/dev/null)" || pb=""
  tb="$(${DATA_SUDO} stat -c %s "$db" 2>/dev/null)" || tb=""
  row T1-3 db:live_file "${pb:-?} bytes · $(kv_get "$evi/db-package-info.txt" journal_mode)" \
    "${tb:-?} bytes · $(kv_get "$evi/db-target-info.txt" journal_mode)" INFO "라이브 파일 해시는 설계상 다름(WAL·경로 재작성)"
}

cmp_rag() {  # T1-3 RAG — 색인 내용 해시 (기준선 없으면 문서 수만)
  local pkg="$1" evi="$2" fmt="$3" bst="$4" rc store
  if [ "$fmt" -ge 2 ] && [ -f "$pkg/baseline-rag.tsv" ]; then
    if rag_hash_all "$evi/rag-target.tsv" "$evi/rag-docs-target.tsv"; then
      rc=0
      mc_rows "$CMP_TMP/rows-rag.tsv" compare-tsv --test T1-3 --prefix rag: --source "$pkg/baseline-rag.tsv" \
        --target "$evi/rag-target.tsv" --bytes-col 3 || rc=$?
      mc_err "$rc" T1-3 rag: compare-tsv
      # 인덱스 내용 행(매핑 · 설정 · 요약 제외)이 다르면 어느 문서가 다른지 짚는다
      if [ -f "$pkg/baseline-rag-docs.tsv" ] \
         && awk -F'\t' '$2 ~ /^rag:/ && $2 !~ /#/ && $2 != "rag:summary" && $5 == "FAIL" {f = 1} END {exit !f}' \
              "$CMP_TMP/rows-rag.tsv" 2>/dev/null; then
        rc=0
        mc_rows "$CMP_TMP/rows-rag-docs.tsv" diff-docs --source "$pkg/baseline-rag-docs.tsv" \
          --target "$evi/rag-docs-target.tsv" --limit 20 || rc=$?
        mc_err "$rc" T1-3 rag-docs diff-docs
      fi
    else
      row T1-3 rag - - FAIL "타겟 색인 해시 계산 실패 (scroll · migcheck rag-hash)"
    fi
  else
    if doc_counts > "$evi/doccount-target.tsv" 2>/dev/null; then
      rc=0
      mc_rows "$CMP_TMP/rows-rag-count.tsv" compare-tsv --test T1-3 --prefix rag-count: --source "$pkg/doccount.tsv" \
        --target "$evi/doccount-target.tsv" || rc=$?
      mc_err "$rc" T1-3 rag-count: compare-tsv
    else
      row T1-3 rag-count: - - FAIL "타겟 문서 수를 읽지 못했습니다"
    fi
    local why="${bst:-PACKAGE_FORMAT=$fmt}"
    # package.env 는 기준선이 있다고(ok) 하는데 파일이 없다 = 패키지를 구형 fetch 로 받았거나 파일이 빠졌다
    if [ "$fmt" -ge 2 ] && [ "$bst" = ok ]; then why="baseline-rag.tsv 없음 — package.env 는 ok · 새 package.sh fetch 로 다시 받으세요"; fi
    row T1-3 rag:content - - FAIL "기준선 없음/불완전($why) — 내용 해시 미수행"
  fi
  store="$( { os_curl "$OS/_cat/indices?bytes=b&h=index,docs.count,pri.store.size" 2>/dev/null \
            | awk '$1 !~ /^\./ && NF >= 3 {printf "%s%s %s건 %s bytes", sep, $1, $2, $3; sep = " · "}'; } )" || store=""
  row T1-3 rag:store - "${store:-unavailable}" INFO "판정 제외 — 세그먼트 병합 · 레플리카에 따라 달라짐"
}

cmp_uploads() {  # T1-3 업로드 — 패키지 목록(uploads.tar.gz 의 contents.tsv) 대 복원된 최종 위치
  local pkg="$1" evi="$2" dir rc t_rc=0
  if ! tar -xOf "$pkg/uploads.tar.gz" "$MANIFEST_NAME" > "$evi/uploads-source.tsv" 2>/dev/null \
     && ! tar -xOf "$pkg/uploads.tar.gz" "./$MANIFEST_NAME" > "$evi/uploads-source.tsv" 2>/dev/null; then
    row T1-3 upload: - - FAIL "패키지 uploads.tar.gz 에서 목록($MANIFEST_NAME)을 읽지 못했습니다"
    return 0
  fi
  dir="$(data_dir)" || dir=""
  if [ -z "$dir" ]; then
    row T1-3 upload: - - FAIL "타겟 데이터 디렉토리를 찾지 못했습니다"
    return 0
  fi
  SUDO_DIR="$DATA_SUDO" write_manifest "$dir" > "$evi/uploads-target.tsv" 2>/dev/null || t_rc=$?
  if [ "$t_rc" != 0 ]; then
    row T1-3 upload: - - FAIL "타겟 업로드 목록을 만들지 못했습니다 ($dir)"
    return 0
  fi
  rc=0
  mc_rows "$CMP_TMP/rows-upload.tsv" compare-tsv --test T1-3 --prefix upload: --source "$evi/uploads-source.tsv" \
    --target "$evi/uploads-target.tsv" --bytes-col 2 || rc=$?
  mc_err "$rc" T1-3 upload: compare-tsv
}

cmp_golden() {  # T2 — 골든 질문을 같은 조건(질문마다 콜드 로드)으로 다시 묻고 답변 바이트 · 추천 상품을 대조
  local pkg="$1" evi="$2" gst="$3" model raw line id cc q body first=1 unload_fail=0 rc want lst exp got
  local -a plan=()
  if [ "${GOLDEN_CHECK:-1}" = 0 ]; then
    row T2 golden - - SKIP "GOLDEN_CHECK=0"
    return 0
  fi
  if [ "$gst" = ok ] && [ ! -f "$pkg/golden.json" ]; then
    row T2 golden "$gst" - FAIL "golden.json 없음 — package.env 는 GOLDEN_STATUS=ok · 새 package.sh fetch 로 다시 받으세요 — 테스트2 미수행"
    return 0
  fi
  if [ ! -f "$pkg/golden.json" ] || [ "$gst" != ok ]; then
    row T2 golden "${gst:-없음}" - FAIL "골든 기준 없음(${gst:-없음}) — 테스트2 미수행 (소스에서 GOLDEN=1 로 패키지 생성)"
    return 0
  fi
  # golden.json 이 이 패키지의 것인지 — package.env(5종 체크섬) → PACKAGE_FILES_SHA256 → package-files.tsv →
  # golden.json 사슬로 확인한다. golden-compare 는 파일 안의 meta 와 items 만 맞춰 보므로, 다른(오래된 ·
  # 바꿔 넣은) golden.json 이면 T1-2 가 FAIL 이어도 테스트2 가 그것을 기준으로 PASS 처럼 보일 수 있다.
  want="$(pkg_value "$pkg" PACKAGE_FILES_SHA256)"
  lst="$( { sha256sum "$pkg/package-files.tsv" | cut -d' ' -f1; } 2>/dev/null )" || lst=""
  exp="$(awk -F'\t' '$1 == "golden.json" {print $3}' "$pkg/package-files.tsv" 2>/dev/null)" || exp=""
  got="$( { sha256sum "$pkg/golden.json" | cut -d' ' -f1; } 2>/dev/null )" || got=""
  if [ -z "$want" ] || [ "$lst" != "$want" ] || [ -z "$exp" ] || [ "$got" != "$exp" ]; then
    row T2 golden:integrity "${exp:0:12}" "${got:0:12}" FAIL "golden.json 이 패키지 지문(package-files.tsv)과 다름 — 테스트2 미수행"
    return 0
  fi
  row T2 golden:integrity "${exp:0:12}" "${got:0:12}" PASS "패키지 지문과 일치"
  fingerprint "$evi/fingerprint-target.txt" || true
  if ! mc golden-plan --golden "$pkg/golden.json" > "$evi/golden-plan.tsv"; then
    row T2 golden - - FAIL "골든 계획을 읽지 못했습니다 (migcheck golden-plan)"
    return 0
  fi
  model="$(llm_model_name)"
  raw="$evi/golden-raw"
  # 같은 증적 디렉토리를 다시 쓰면 지난 실행의 원시 응답 · qNN.diff 가 남아 이번 결과로 오인된다 — 이 두 하위 디렉토리만 비운다
  rm -rf "$raw" "$evi/golden-diff" 2>/dev/null || true
  mkdir -p "$raw" "$evi/golden-diff" || true
  mapfile -t plan < "$evi/golden-plan.tsv"
  log "   골든 ${#plan[@]}문항 · 모델 $model (호출마다 모델을 내려 콜드 로드)"
  for line in "${plan[@]}"; do
    id=""; cc=""; q=""; body=""
    IFS=$'\t' read -r id cc q body <<< "$line" || true
    [ -n "$id" ] || continue
    llm_unload "$model" || unload_fail=$((unload_fail + 1))
    front_chat "$cc" "$q" "$raw/t-$id-l3"
    if [ "$first" = 1 ]; then
      kv_set "$evi/fingerprint-target.txt" ollama_processor "$(ollama_processor)" 2>/dev/null || true
      first=0
    fi
    # L2 — 소스의 추천 상품으로 생성만 다시 (검색 계층 차이와 생성 계층 차이를 가른다)
    llm_unload "$model" || unload_fail=$((unload_fail + 1))
    ai_generate "$body" "$raw/t-$id-l2"
    log "   $id — L3 $(cat "$raw/t-$id-l3.code" 2>/dev/null) · L2 $(cat "$raw/t-$id-l2.code" 2>/dev/null)"
  done
  rc=0
  mc_rows "$CMP_TMP/rows-golden.tsv" golden-compare --golden "$pkg/golden.json" --raw-dir "$raw" \
    --target-meta "$evi/fingerprint-target.txt" --diff-dir "$evi/golden-diff" || rc=$?
  mc_err "$rc" T2 golden golden-compare
  if [ "$unload_fail" != 0 ]; then
    row T2 llm_unload - "${unload_fail}회 실패" WARN "모델 언로드 확인 실패 — 콜드 로드 조건이 아니었을 수 있음 (/api/ps)"
  fi
}

cmd_compare() {
  local pkg="" evi="" f fmt bst gst sf n_rows n_fail st usage
  usage="사용법: $0 compare <패키지디렉토리> [--evidence 디렉토리]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence)   [ $# -ge 2 ] || die "$usage"; evi="$2"; shift 2 ;;
      --evidence=*) evi="${1#*=}"; shift ;;
      -*)           die "$usage — 모르는 옵션: $1" ;;
      *)            [ -z "$pkg" ] || die "$usage"; pkg="$1"; shift ;;
    esac
  done
  [ -n "$pkg" ] || die "$usage"
  [ -f "$pkg/checksums.sha256" ] || die "패키지가 아닙니다 (checksums.sha256 없음): $pkg"
  pkg="$(cd "$pkg" && pwd)"
  setup_runtime
  need_migcheck
  if [ -z "$evi" ]; then evi="$(mktemp -d)" || die "증적 디렉토리를 만들지 못했습니다"; fi
  mkdir -p "$evi" || die "증적 디렉토리를 만들지 못했습니다: $evi"
  evi="$(cd "$evi" && pwd)"
  cmp_stage "$evi" start     # 같은 증적 디렉토리를 다시 쓸 때 지난 실행의 done 이 남지 않게
  CMP_TMP="$(mktemp -d)" || die "임시 디렉토리를 만들지 못했습니다"
  trap cleanup_tmp EXIT
  CMP_ROWS="$CMP_TMP/rows.tsv"
  : > "$CMP_ROWS"

  # ROW 는 fd 3(원래 stdout)으로만 — 그 밖의 출력(log · 하위 명령의 잡음)은 전부 stderr 로 돌려
  # stdout 을 ROW 전용으로 지킨다 (verify.sh 가 stdout 을 rows.tsv 로 받는다).
  exec 3>&1 1>&2

  fmt="$(num "$(pkg_value "$pkg" PACKAGE_FORMAT)")"; [ "$fmt" -ge 1 ] || fmt=1
  bst="$(pkg_value "$pkg" BASELINE_STATUS)"
  gst="$(pkg_value "$pkg" GOLDEN_STATUS)"
  GOLDEN_CHECK="${GOLDEN_CHECK:-1}"
  sf="$(pkg_value "$pkg" SOURCE_FORM)"; sf="${sf:-$(pkg_value "$pkg" SOURCE_RUNTIME)}"
  log "이관 동등성 비교 — $pkg (FORMAT $fmt · 기준선 ${bst:-없음} · 골든 ${gst:-없음} · 원본 ${sf:-?} → $SOURCE_FORM_NAME)"
  for f in "$pkg"/baseline-*.tsv "$pkg/golden.json" "$pkg/fingerprint-source.txt" "$pkg/package-files.tsv" "$pkg/package.env"; do
    if [ -f "$f" ]; then cp "$f" "$evi/" 2>/dev/null || warn "증적 복사 실패: $f"; fi
  done

  log "T1-1 서비스 · 컨테이너 수"
  cmp_stage "$evi" T1-1
  cmp_services "$pkg" "$evi"
  log "T1-2 패키지 용량 · 해시"
  cmp_stage "$evi" T1-2
  cmp_package "$pkg" "$evi" "$fmt"
  log "T1-3 DB"
  cmp_stage "$evi" T1-3
  # 재실행 · 부분 복원 · FORCE_RESTORE 여부와 무관하게 "지금 타겟 = 패키지 기준선" 을 본다 — 복원 기록은 참고로 싣는다
  st=""
  if [ -f "$pkg/.restore-state" ]; then st="$(paste -sd' ' - < "$pkg/.restore-state")" || st=""; fi
  row T1-3 restore:state - "${st:-기록 없음}" INFO "package.sh restore 기록 (.restore-state)"
  cmp_db "$pkg" "$evi"
  log "T1-3 RAG"
  cmp_rag "$pkg" "$evi" "$fmt" "$bst"
  log "T1-3 업로드 파일"
  cmp_uploads "$pkg" "$evi"
  log "T2 LLM 응답 완전 일치"
  cmp_stage "$evi" T2
  cmp_golden "$pkg" "$evi" "$gst"
  cmp_stage "$evi" "done"

  n_rows="$(awk 'END {print NR}' "$CMP_ROWS" 2>/dev/null)" || n_rows="?"
  n_fail="$(awk -F'\t' '$5 == "FAIL" {n++} END {print n + 0}' "$CMP_ROWS" 2>/dev/null)" || n_fail=1
  log "비교 완료 — ROW ${n_rows}개 · FAIL ${n_fail}개 · 증적 $evi"
  [ "$n_fail" = 0 ] || exit 1
}

case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  compare) shift; cmd_compare "$@" ;;
  *)
    cat >&2 <<EOF
사용법:
  $0 backup [출력디렉토리]                 소스 — 패키지 생성 (UPLOAD_URI=s3://… 면 업로드까지)
                                           GOLDEN=1 이면 골든 응답(테스트2 기준)까지 — LLM_TEMPERATURE=0 LLM_SEED=42 로 기동된 소스에서
  $0 fetch <URI> [받을디렉토리]            타겟 — 패키지 수신 + 체크섬 확인
  $0 restore <패키지디렉토리> [all|index|data]   타겟 — 앱 기동 전에 복원
  $0 compare <패키지디렉토리> [--evidence 디렉토리]
                                           타겟 — 이관 동등성 비교 (복원 · 앱 기동 뒤, ROW 는 stdout · 로그는 stderr)
EOF
    exit 1 ;;
esac
