#!/usr/bin/env bash
# ===========================================================
# [부트스트랩] 신규 VM 진입점 — 사람이 하는 일은 VM 생성과 SSH 접속까지 (Shell 설치형 A)
#
#   curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/local/bootstrap.sh | bash
#
#   이 한 줄이 코드 확보 · GPU 드라이버 · 설치 · 데이터 복원 · 기동 · 검증을 무인으로 수행한다
#   (postCommands 페이로드와 동일 — LexAI deploy/native/bootstrap.sh 와 같은 방식).
#   이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주면 색인 · DB 까지 받아 복원한다:
#
#     curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/<시각> bash
#
#   ※ Docker Compose(B) 트랙은 이 진입점을 쓰지 않는다 — scripts/compose/deploy.sh (clone 없음).
#
#   이후 (첫 실행이 자신을 /usr/local/bin/bootstrap.sh 로 설치하고, 브랜치는
#   기존 clone(~/WidgetRAG)에서 자동 유도하므로 짧게 친다):
#
#     bootstrap.sh              # = --start
#     bootstrap.sh --install    # 준비만 (기동 전까지) — NO_START=1 과 같다
#
#   동작 순서 (멱등 — 이미 된 단계는 건너뛴다)
#     0) root 로 실행되면(이관 도구의 postCommands) uid 1000 사용자로 이어서 실행한다.
#        서비스 · 데이터가 /root 아래에 생겨, 나중에 사람이 SSH 로 붙었을 때 아무것도 안 보이는
#        상황을 막는다 (systemd 유닛의 User= · 파일 소유권 · venv 경로가 전부 그 사용자 기준).
#     1) git 설치 → clone (있으면 fetch + reset --hard origin/BRANCH) → 디스크 사본으로 다시 실행.
#        ★ 이관 패키지에 실행 파일 층(app-tree.tar.gz)이 있으면 — SNAPSHOT_URI 또는 PACKAGE_DIR — clone 대신 그 트리를
#          TARGET_DIR 에 풀고 그 안의 bootstrap.sh 로 갈아탄다. 소스에서 빌드된 jar · pip 잠금 목록을 그대로 쓰므로
#          타겟에 git · Maven · 소스가 필요 없다 (CODE_SOURCE=auto|package|git, 트리 루트의 app-tree.env 가 표식).
#        ★ curl | bash 로 들어오면 스크립트 본문이 stdin 이다. 뒤에서 stdin 을 읽는 명령이 돌면
#          남은 본문을 삼켜 에러 한 줄 없이 끝난다 (LexAI 결함 4). 사본으로 갈아타 stdin 과 끊는다.
#     2) 자기 설치 — clone된 스크립트를 /usr/local/bin/bootstrap.sh 로 복사
#     3) NVIDIA 드라이버 — GPU가 있는데 드라이버가 없으면 설치 후 재부팅.
#        설치 전에 커널 메타 패키지를 올려 드라이버 모듈 · 헤더의 커널 ABI 를 맞추고, 설치 뒤에는 패키지 상태 ·
#        모듈 파일로 성공을 확인한 뒤에만 재부팅한다 (아래 T-004 참고). 재부팅 뒤에도 안 뜨면 반복하지 않고 멈춘다.
#        재부팅 전에 systemd oneshot(widgetrag-bootstrap-resume)을 등록해 같은 단계부터 자동 재개.
#        curl | bash 앞에 붙인 환경변수(SNAPSHOT_URI 등)는 재부팅 뒤에 사라지므로 함께 넘긴다.
#        재개 뒤에는 유닛을 disable 만 한다 — 파일 삭제는 5) 에서 (아래 T-002 참고).
#     4) 실행 형태 진입
#        --start   : install.sh → start.sh (인프라 → 패키지 복원 → 앱 → 검증)  ← 기본
#        --install : install.sh            (도구 설치 + 설정, 기동 전까지)
#     5) 재개 유닛 파일 정리 — 모든 단계가 끝난 뒤에만. 유닛 안에서 실행 중이면 daemon-reload 는 생략.
#        ★ 2026-10-16 T-002: 재개 직후 유닛 파일을 지우고 daemon-reload 하면 systemd 가 실행 중인 유닛의
#          설정(TimeoutStartSec=0)을 잃고 기본 90초 타임아웃으로 설치 도중 프로세스를 종료시켰다.
#
#   환경변수 (전부 선택)
#     REPO_URL      기본 https://github.com/ghd329/WidgetRAG.git — public, 자격증명 불필요
#                   (Cloud-Barista Private 이전 시 deploy key/PAT 주입 방식 협의 필요)
#     BRANCH        미지정 시 기존 clone 의 현재 브랜치 → 없으면 feat/20260922-change-sqlite
#     COMMIT        해시 고정 (실증 재현성용)
#     TARGET_DIR    기본 $HOME/WidgetRAG
#     TARGET_USER   root 로 실행될 때 서비스를 돌릴 사용자 (기본 uid 1000)
#     SNAPSHOT_URI  이관 패키지 위치 (s3:// · gs:// · https:// · 로컬 경로) — scripts/package.sh
#                   ※ rsync 로 PACKAGE_DIR(기본 $HOME/widgetrag-package) 에 넣어 두었으면 SNAPSHOT_URI 없이 실행한다
#     CODE_SOURCE   auto(기본) | package | git — package: 패키지의 실행 파일 트리로만 기동(없으면 실패), git: 패키지가 있어도 clone
#     PACKAGE_DIR   받은 패키지 위치 (기본 $HOME/widgetrag-package — root 로 실행되면 서비스 사용자의 홈 기준)
#     NO_DRIVER=1   드라이버 단계 스킵 (GPU 이미지 · GPU 없는 검증 VM)
#     NVIDIA_DRIVER_SERIES  설치할 드라이버 시리즈 (기본 595 → ubuntu-drivers install nvidia:595). 빈 값이면 추천판.
#                   같은 이미지 · 같은 명령인데 1차 580 · 2차 595 가 깔린 적이 있어(2026-10-16) 소스 · 타겟을 같은
#                   버전으로 맞추려고 고정한다. 지정판 설치가 실패하면 추천판으로 진행한다.
#     NO_START=1    준비만 하고 기동은 안 함 (= --install)
#     OLLAMA_VERSION Ollama 고정 버전 (기본 0.34.3 — Docker Compose llm 이미지와 같게, env.sh · 빈 값이면 최신)
#     COMPARE=1     마지막 검증에서 이관 동등성까지 대조 (GOLDEN_CHECK=0 이면 LLM 골든 대조 생략)
#
#   재개 유닛 로그: sudo journalctl -u widgetrag-bootstrap-resume -f
# ===========================================================
set -euo pipefail

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춘다.
export DEBIAN_FRONTEND=noninteractive
# 비대화형 실행(원격 커맨드 · systemd)에서 HOME 이 비어 있을 수 있다 — 계정 정보에서 채운다
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"

DEFAULT_BRANCH="feat/20260922-change-sqlite"
# 빈 값(NVIDIA_DRIVER_SERIES=)은 "추천판" 이라는 뜻이라 ':-' 가 아니라 '-' 로 기본값을 준다
NVIDIA_DRIVER_SERIES="${NVIDIA_DRIVER_SERIES-595}"
REPO_URL="${REPO_URL:-https://github.com/ghd329/WidgetRAG.git}"
BRANCH="${BRANCH:-}"          # 미지정 시: 기존 clone의 현재 브랜치 → 없으면 DEFAULT_BRANCH
COMMIT="${COMMIT:-}"
CODE_SOURCE="${CODE_SOURCE:-auto}"   # auto | package | git — 아래 app_tree_file 참고
MODE="${1:-}"
RESUME_UNIT="widgetrag-bootstrap-resume"
RESUME_ENV="/etc/widgetrag/bootstrap-resume.env"

# 재실행 · 재부팅 재개 때 넘겨야 하는 값 — 설정된 것만 넘긴다
PASS_VARS=(REPO_URL BRANCH COMMIT TARGET_DIR SNAPSHOT_URI S3_ENDPOINT_URL NO_DRIVER FORCE_RESTORE
           LLM_TEMPERATURE LLM_SEED APP_TZ OLLAMA_MODEL OLLAMA_VERSION FORM RUNS REQUIRE_DATA VERIFY_ADMIN_PASSWORD
           COMPARE GOLDEN_CHECK EXPECT_SERVICE_COUNT CODE_SOURCE PACKAGE_DIR
           AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION)

# 이관 도구로 실행되면 TTY 가 없고 출력이 로그로 수집된다 — 그때는 색상 제어문자를 쓰지 않는다.
if [ -t 1 ]; then
  log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
  die() { printf '\033[1;31m[bootstrap][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
else
  log() { printf '[bootstrap] %s\n' "$*"; }
  die() { printf '[bootstrap][FAIL] %s\n' "$*" >&2; exit 1; }
fi

[ "$(uname -s)" = "Linux" ] || die "실증 환경(Ubuntu Linux) 전용 진입점입니다"

case "$MODE" in
  "")                    if [ "${NO_START:-0}" = 1 ]; then MODE=--install; else MODE=--start; fi ;;
  --start|--install)     : ;;
  --no-start)            MODE=--install ;;
  *) die "알 수 없는 옵션: $MODE (--start | --install) — Docker Compose(B)는 scripts/compose/deploy.sh 를 사용" ;;
esac

apt_get() {  # apt_get <인자...> — root 면 그대로, 아니면 sudo env 로 비대화형 전달
  if [ "$(id -u)" -eq 0 ]; then env DEBIAN_FRONTEND=noninteractive apt-get "$@"
  else sudo env DEBIAN_FRONTEND=noninteractive apt-get "$@"; fi
}

pass_env() {  # 설정된 PASS_VARS 를 NUL 구분 KEY=VALUE 로 출력
  local v
  for v in "${PASS_VARS[@]}"; do
    if [ -n "${!v:-}" ]; then
      printf '%s\0' "$v=${!v}"
    elif [ "$v" = OLLAMA_VERSION ] && [ -n "${!v+x}" ]; then
      # OLLAMA_VERSION= (빈 값)은 "최신 설치" 라는 뜻이다 — 빈 값도 넘겨야 env.sh 의 기본값(고정 버전)으로 바뀌지 않는다
      printf '%s\0' "$v="
    fi
  done
  return 0
}

sync_repo() {  # sync_repo [실행 접두사...] — clone 또는 갱신 (root 경로에서는 sudo -u <사용자> -H)
  local as=("$@")
  if [ -d "$TARGET_DIR/.git" ]; then
    if [ -z "$BRANCH" ]; then
      # 기존 clone의 브랜치를 그대로 따라간다 — 짧은 재실행(bootstrap.sh)의 핵심
      BRANCH="$("${as[@]}" git -C "$TARGET_DIR" symbolic-ref --short -q HEAD || true)"
    fi
    if [ -z "$BRANCH" ]; then
      log "기존 저장소가 커밋 고정(detached) 상태 — 갱신 없이 현재 코드로 진행 (갱신하려면 BRANCH= 지정)"
    else
      log "기존 저장소 갱신: $TARGET_DIR (origin/$BRANCH 기준으로 동기화)"
      "${as[@]}" git -C "$TARGET_DIR" fetch -q origin
      "${as[@]}" git -C "$TARGET_DIR" checkout -q "$BRANCH"
      "${as[@]}" git -C "$TARGET_DIR" reset -q --hard "origin/$BRANCH"
    fi
  else
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
    # rsync 시절 사본 등 git 저장소가 아닌 디렉토리가 있으면 백업 후 clone
    # (저장소 디렉토리의 내용물은 전부 재생성 가능 — 운영 데이터는 ~/widgetrag-data에 별도)
    if [ -e "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
      local bak; bak="$TARGET_DIR.bak.$(date +%Y%m%d%H%M%S)"
      log "비-git 디렉토리 발견 (rsync 사본 등) — 백업 후 clone: $TARGET_DIR → $bak"
      "${as[@]}" mv "$TARGET_DIR" "$bak"
    fi
    log "clone: $REPO_URL ($BRANCH) → $TARGET_DIR"
    "${as[@]}" git clone -q -b "$BRANCH" "$REPO_URL" "$TARGET_DIR"
  fi
  if [ -n "$COMMIT" ]; then
    log "커밋 고정: $COMMIT"
    "${as[@]}" git -C "$TARGET_DIR" checkout --quiet "$COMMIT"
  fi
  log "코드 준비 완료: $("${as[@]}" git -C "$TARGET_DIR" rev-parse --short HEAD) (요청: ${COMMIT:-${BRANCH:-현재 커밋}})"
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  log "git 설치 (apt)"
  apt_get update -qq
  apt_get install -y -q git ca-certificates curl >/dev/null
}

ensure_curl() {  # 패키지 모드는 git 이 필요 없다 — 원격 패키지를 받을 curl 만 보장한다
  command -v curl >/dev/null 2>&1 && return 0
  apt_get update -qq
  apt_get install -y -q curl ca-certificates >/dev/null
}

# ---------- 이관 패키지의 실행 파일 층 (app-tree.tar.gz) ----------
fetch_pkg_min() {  # fetch_pkg_min <URI> <받을디렉토리> [실행 접두사...] — 트리 전개에 필요한 세 파일만 (package.sh fetch 와 같은 규칙)
  # 진짜 fetch(package.sh)는 트리 안에 있어 아직 없다. .source 는 쓰지 않는다 — 뒤에 도는 fetch 가 나머지를 제대로 받게.
  local uri="$1" dst="$2"; shift 2
  local as=("$@") f
  "${as[@]}" mkdir -p "$dst"
  for f in package.env package-files.tsv app-tree.tar.gz; do
    case "$uri" in
      s3://*)             command -v aws >/dev/null 2>&1 || die "aws CLI 가 없습니다 — 패키지를 로컬 경로 · https 로 두거나 aws 를 먼저 설치하세요"
                          "${as[@]}" aws ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} s3 cp "$uri/$f" "$dst/$f" --only-show-errors || true ;;
      gs://*)             command -v gsutil >/dev/null 2>&1 || die "gsutil 이 없습니다 — 패키지를 로컬 경로 · https 로 두거나 gsutil 을 먼저 설치하세요"
                          "${as[@]}" gsutil -q cp "$uri/$f" "$dst/$f" || true ;;
      http://*|https://*) "${as[@]}" curl -fsSL "$uri/$f" -o "$dst/$f" || true ;;
      *)                  if [ -f "$uri/$f" ]; then "${as[@]}" cp "$uri/$f" "$dst/$f"; fi ;;
    esac
  done
  return 0
}

app_tree_file() {  # app_tree_file [실행 접두사...] — 패키지의 app-tree.tar.gz 경로를 stdout 으로 (없으면 빈 값 → git 모드)
  local as=("$@") src=""
  [ "$CODE_SOURCE" != git ] || return 0
  if [ -n "${SNAPSHOT_URI:-}" ]; then
    case "$SNAPSHOT_URI" in
      s3://*|gs://*|http://*|https://*)
        { ensure_curl; fetch_pkg_min "$SNAPSHOT_URI" "$PACKAGE_DIR" "${as[@]}"; } >&2   # 로그가 stdout(반환값)에 섞이지 않게
        src="$PACKAGE_DIR" ;;
      *) if [ -d "$SNAPSHOT_URI" ]; then src="$SNAPSHOT_URI"; fi ;;    # 로컬 디렉토리 — 복사 없이 제자리에서 읽는다
    esac
  fi
  [ -n "$src" ] || src="$PACKAGE_DIR"                                   # rsync 로 미리 넣어 둔 패키지
  if [ -f "$src/app-tree.tar.gz" ] && [ -f "$src/package-files.tsv" ]; then
    printf '%s\n' "$src/app-tree.tar.gz"
  elif [ "$CODE_SOURCE" = package ]; then
    die "CODE_SOURCE=package 인데 패키지에 app-tree.tar.gz 가 없습니다 (${SNAPSHOT_URI:-$PACKAGE_DIR}) — 소스가 Shell 설치형이고 backup 이 새 판(실행 파일 층)인지 확인"
  fi
  return 0
}

unpack_app_tree() {  # unpack_app_tree <tar> [실행 접두사...] — 트리를 TARGET_DIR 에 전개 (실행 사용자 소유). 같은 트리면 건너뜀
  local tar="$1"; shift
  local as=("$@") pkgdir want have bak="" bad
  pkgdir="$(dirname "$tar")"
  want="$(awk -F'\t' '$1 == "app-tree.tar.gz" {print $3}' "$pkgdir/package-files.tsv" | tail -1)"
  [ -n "$want" ] || die "package-files.tsv 에 app-tree.tar.gz 가 없습니다 ($pkgdir)"
  have="$(sha256sum "$tar" | cut -d' ' -f1)"
  [ "$have" = "$want" ] || die "app-tree.tar.gz 해시 불일치 — 전송 중 손상 (기대 ${want:0:12} / 실제 ${have:0:12})"
  if [ -f "$TARGET_DIR/.app-tree.sha256" ] && [ "$(cat "$TARGET_DIR/.app-tree.sha256")" = "$have" ]; then
    log "패키지 트리 이미 전개됨: $TARGET_DIR (${have:0:12}) — 그대로 사용"
    return 0
  fi
  if [ -e "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    bak="$TARGET_DIR.bak.$(date +%Y%m%d%H%M%S)"
    if [ -d "$TARGET_DIR/.git" ]; then log "기존 git clone 을 비켜 둠: $TARGET_DIR → $bak"
    else log "기존 트리를 비켜 둠: $TARGET_DIR → $bak"; fi
    "${as[@]}" mv "$TARGET_DIR" "$bak"
  fi
  log "패키지 트리 전개: $tar → $TARGET_DIR (소스에서 빌드된 산출물 — 타겟에서 빌드하지 않는다)"
  "${as[@]}" mkdir -p "$TARGET_DIR"
  # 반드시 실행 사용자로 푼다 — root 가 풀면 venv · logs · nginx 워커가 그 사용자로 쓰지 못한다
  "${as[@]}" tar -xf "$tar" -C "$TARGET_DIR" --no-same-owner
  bad="$( { awk -F'\t' 'NF == 3 {print $3 "  " $1}' "$TARGET_DIR/app-manifest.tsv" \
          | "${as[@]}" sh -c "cd '$TARGET_DIR' && sha256sum -c --quiet" 2>&1 | head -5; } || true)"
  [ -z "$bad" ] || die "전개된 트리가 목록(app-manifest.tsv)과 다릅니다: $bad"
  if [ -n "$bak" ]; then   # 다시 만들 필요 없는 것은 되돌린다 — venv(같은 경로라 유효 · 40 이 잠금 목록으로 맞춘다) · 이 환경의 관리자 비밀번호
    if [ -d "$bak/ai-server/.venv" ]; then "${as[@]}" mv "$bak/ai-server/.venv" "$TARGET_DIR/ai-server/.venv"; fi
    if [ -f "$bak/scripts/local/.admin-password" ]; then "${as[@]}" cp -p "$bak/scripts/local/.admin-password" "$TARGET_DIR/scripts/local/.admin-password"; fi
  fi
  printf '%s\n' "$have" | "${as[@]}" tee "$TARGET_DIR/.app-tree.sha256" >/dev/null
  log "트리 준비 완료: 커밋 $(grep '^APP_CODE_REF=' "$TARGET_DIR/app-tree.env" | cut -d= -f2-) · 파일 $(grep -c . "$TARGET_DIR/app-manifest.tsv" || true)개"
  return 0
}

# ---------- 0. 실행 사용자 — root 면 uid 1000 사용자로 이어서 ----------
if [ "$(id -u)" -eq 0 ] && [ "${WIDGETRAG_REEXEC:-0}" != 1 ]; then
  RUN_USER="${TARGET_USER:-${SUDO_USER:-}}"
  if [ -z "$RUN_USER" ] || [ "$RUN_USER" = root ]; then
    RUN_USER="$( { getent passwd 1000 | cut -d: -f1; } || true )"
  fi
  [ -n "$RUN_USER" ] || die "일반 사용자를 찾지 못했습니다 — TARGET_USER 로 지정하세요"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  TARGET_DIR="${TARGET_DIR:-$RUN_HOME/WidgetRAG}"
  PACKAGE_DIR="${PACKAGE_DIR:-$RUN_HOME/widgetrag-package}"   # root 의 $HOME(/root) 이 아니라 서비스 사용자 기준
  log "root 로 실행되었습니다 — ${RUN_USER} 사용자로 이어서 진행합니다"

  # 재실행할 스크립트가 디스크에 있어야 한다 — 저장소(또는 패키지 트리)를 그 사용자로 받는다 (root 가 받으면
  # 소유자가 달라 이후 git 이 dubious ownership 으로 거부하고, venv · logs 도 그 사용자가 쓰지 못한다)
  APP_TREE_FILE="$(app_tree_file sudo -u "$RUN_USER" -H)"
  if [ -n "$APP_TREE_FILE" ]; then
    unpack_app_tree "$APP_TREE_FILE" sudo -u "$RUN_USER" -H
  else
    ensure_git
    sync_repo sudo -u "$RUN_USER" -H
  fi
  mapfile -d '' ENV_ARGS < <(pass_env)
  exec sudo -u "$RUN_USER" -H env WIDGETRAG_REEXEC=1 WIDGETRAG_FROMFILE=1 WIDGETRAG_RESUME="${WIDGETRAG_RESUME:-0}" "${ENV_ARGS[@]}" \
    TARGET_DIR="$TARGET_DIR" PACKAGE_DIR="$PACKAGE_DIR" BRANCH="$BRANCH" \
    bash "$TARGET_DIR/scripts/local/bootstrap.sh" "$MODE" </dev/null
fi

TARGET_DIR="${TARGET_DIR:-$HOME/WidgetRAG}"
PACKAGE_DIR="${PACKAGE_DIR:-$HOME/widgetrag-package}"

# ---------- 1. 코드 확보 → 디스크 사본으로 다시 실행 ----------
if [ "${WIDGETRAG_FROMFILE:-0}" != 1 ]; then
  APP_TREE_FILE="$(app_tree_file)"
  if [ -n "$APP_TREE_FILE" ]; then
    unpack_app_tree "$APP_TREE_FILE"       # 이관: 패키지의 실행 파일 트리 (빌드 없음)
  else
    ensure_git
    sync_repo                              # 백지 구축: 저장소 clone → 타겟에서 빌드
  fi
  # 사본에서 실행 중일 때(WIDGETRAG_FROMFILE=1)는 저장소를 건드리지 않는다 — bash 는 스크립트를
  # 조금씩 읽어가므로, 실행 중인 파일을 git 이 덮어쓰면 남은 부분이 깨진다.
  export WIDGETRAG_FROMFILE=1 REPO_URL BRANCH COMMIT TARGET_DIR PACKAGE_DIR CODE_SOURCE
  exec bash "$TARGET_DIR/scripts/local/bootstrap.sh" "$MODE" </dev/null
fi

# ---------- 2. 자기 설치 — 이후에는 어디서든 `bootstrap.sh` 로 호출 ----------
if ! cmp -s "$TARGET_DIR/scripts/local/bootstrap.sh" /usr/local/bin/bootstrap.sh 2>/dev/null; then
  sudo install -m 755 "$TARGET_DIR/scripts/local/bootstrap.sh" /usr/local/bin/bootstrap.sh
  log "커맨드 설치: /usr/local/bin/bootstrap.sh — 다음부터는 'bootstrap.sh' 로 실행"
fi

# ---------- 3. NVIDIA 드라이버 (GPU 존재 시) ----------
need_driver() {
  [ "${NO_DRIVER:-}" = "1" ] && return 1
  nvidia-smi >/dev/null 2>&1 && return 1          # 이미 동작
  command -v lspci >/dev/null 2>&1 || apt_get install -y -q pciutils >/dev/null 2>&1 || true
  lspci 2>/dev/null | grep -qi nvidia              # NVIDIA GPU가 실재할 때만
}

next_kernel() {  # 다음 부팅에 올라올 커널 ABI — /boot/vmlinuz 가 가리키는 것, 없으면 설치된 것 중 가장 높은 판
  local k
  k="$(readlink -f /boot/vmlinuz 2>/dev/null || true)"; k="${k##*/vmlinuz-}"
  if [ -n "$k" ] && [ -d "/lib/modules/$k" ]; then echo "$k"; else ls -1 /lib/modules 2>/dev/null | sort -V | tail -1; fi
}

install_kernel_meta() {  # 커널 메타 패키지(이미지 · 헤더 · 모듈)를 저장소의 최신 ABI 로 — 드라이버 모듈과 헤더를 같은 ABI 로 맞춘다
  # ★ 2026-10-19 T-004: ubuntu-drivers 가 고르는 미리 컴파일된 모듈(linux-modules-nvidia-<시리즈>-<flavour>)은
  #   저장소의 최신 커널 ABI 용이라 새 커널 이미지는 함께 끌어오지만, 같은 ABI 의 헤더는 의존성에 없다.
  #   구성 단계에서 그 헤더의 objtool · module.lds 로 .ko 를 링크하므로 헤더가 없으면 링크가 깨지고
  #   nvidia-driver 가 미구성(iU)으로 남는다. 이미지의 헤더가 한 판 뒤처진 상태(1013 헤더 · 1014 모듈)에서 났다.
  local flavour meta
  flavour="$(uname -r | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-//')"   # 7.0.0-1013-aws → aws
  meta="linux-$flavour"
  # 판정은 출력을 변수에 담아서 한다 — 파이프에 grep -q 를 걸면 grep 이 먼저 끝나면서 apt-cache 가 SIGPIPE(141)로
  # 죽고, pipefail 아래서 조건이 거짓이 된다 (실 VM 에서 linux-aws 를 '찾지 못함' 으로 빠진 원인)
  local policy; policy="$(apt-cache policy "$meta" 2>/dev/null || true)"
  if grep -q 'Candidate: [0-9]' <<<"$policy"; then
    log "커널 메타 패키지 갱신: $meta (드라이버 모듈 · 헤더를 같은 커널 ABI 로)"
    apt_get install -y -q "$meta"
  else
    log "커널 메타 패키지 $meta 를 찾지 못함 — 현재 커널의 헤더만 설치"
    apt_get install -y -q "linux-headers-$(uname -r)"
  fi
}

driver_ready() {  # 드라이버 패키지가 전부 구성(ii)됐고, 다음 부팅 커널용 nvidia 모듈이 실재하는지
  # ubuntu-drivers 는 apt 가 실패해도 0 으로 끝난다 — 종료 코드가 아니라 패키지 상태 · 모듈 파일로 판정한다
  local half k
  half="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-*' 'linux-modules-nvidia-*' 2>/dev/null | grep -E '^i[^i]' || true)"
  if [ -n "$half" ]; then
    log "미구성 드라이버 패키지:"; printf '%s\n' "$half" | sed 's/^/    /'
    return 1
  fi
  local drivers; drivers="$(dpkg-query -W -f='${db:Status-Abbrev}\n' 'nvidia-driver-*' 2>/dev/null || true)"
  grep -q '^ii' <<<"$drivers" || { log "nvidia-driver-* 패키지가 설치되지 않음"; return 1; }
  k="$(next_kernel)"
  modinfo -k "$k" nvidia >/dev/null 2>&1 || [ -n "$(find "/lib/modules/$k" -name 'nvidia.ko*' -print -quit 2>/dev/null)" ] \
    || { log "커널 $k 용 nvidia 모듈이 없음"; return 1; }
}

repair_driver_packages() {  # 미구성 패키지가 남았을 때 한 번 손본다 — 모듈이 노리는 커널의 헤더를 넣고 다시 구성
  local k; k="$(next_kernel)"
  log "드라이버 패키지 재구성 시도: linux-headers-$k 설치 후 dpkg --configure -a"
  apt_get install -y -q "linux-headers-$k" || true
  sudo dpkg --configure -a || true
}

# 재부팅 뒤 재개 — 부팅 직후에는 커널 모듈이 올라와도 /dev/nvidia* 장치 노드가 늦게 생긴다 (udev · nvidia-persistenced,
# 실측 부팅 +20초. 재개 유닛은 network-online 직후 +6초에 돈다). 일반 사용자의 nvidia-smi 는 노드가 없으면 실패하므로
# 기다리며 재시도하고, 중간에 root 로 한 번 불러 노드를 만들어 준다. 그래도 안 뜨면 다시 설치 · 재부팅으로 돌지 않고 멈춘다.
if need_driver && [ "${WIDGETRAG_RESUME:-0}" = 1 ]; then
  log "재부팅 후 재개 — 드라이버가 준비될 때까지 대기 (최대 120초)"
  for i in $(seq 1 40); do
    nvidia-smi >/dev/null 2>&1 && break
    if [ "$i" -eq 5 ]; then sudo modprobe nvidia >/dev/null 2>&1 || true; sudo nvidia-smi >/dev/null 2>&1 || true; fi
    sleep 3
  done
  nvidia-smi >/dev/null 2>&1 \
    || die "재부팅 후에도 NVIDIA 드라이버가 동작하지 않음 — 재부팅을 반복하지 않고 멈춤 (확인: nvidia-smi · dmesg | grep -i nvidia · dpkg -l | grep -E '^i[^i]')"
  log "드라이버 준비 확인 (약 $(( (i-1)*3 ))초 대기)"
fi

if need_driver; then
  log "NVIDIA 드라이버 설치 (GPU 감지됨, 드라이버 미동작) — 설치 후 재부팅·자동 재개"
  apt_get update -qq
  install_kernel_meta
  apt_get install -y -q ubuntu-drivers-common
  if [ -n "$NVIDIA_DRIVER_SERIES" ]; then
    log "드라이버 시리즈 고정: nvidia:$NVIDIA_DRIVER_SERIES (소스 · 타겟을 같은 버전으로)"
    sudo ubuntu-drivers install "nvidia:$NVIDIA_DRIVER_SERIES" || true
    driver_ready || repair_driver_packages
    driver_ready || { log "nvidia:$NVIDIA_DRIVER_SERIES 설치가 완료되지 않음 — ubuntu-drivers 추천판으로 진행"; sudo ubuntu-drivers install || true; }
  else
    sudo ubuntu-drivers install || true
  fi
  driver_ready || repair_driver_packages
  driver_ready || die "NVIDIA 드라이버 패키지가 구성되지 않음 — 재부팅하지 않고 멈춤 (위 미구성 패키지 확인 → sudo dpkg --configure -a 뒤 다시 실행)"

  # ★ 재부팅 뒤에는 환경이 새로 시작된다. curl | bash 앞에 붙인 변수(SNAPSHOT_URI 등)는
  #   여기 적어두지 않으면 사라진다 (LexAI 에서 ALLOW_EMPTY_INDEX 가 유실된 결함과 같은 계열).
  #   자격증명이 섞일 수 있어 유닛 파일(644)이 아니라 root 600 환경 파일에 둔다.
  log "재부팅 후 자동 재개 유닛 등록: $RESUME_UNIT (로그: sudo journalctl -u $RESUME_UNIT -f)"
  sudo install -d -m 755 "$(dirname "$RESUME_ENV")"
  {
    echo "HOME=$HOME"
    echo "WIDGETRAG_FROMFILE=1"
    echo "WIDGETRAG_RESUME=1"
    pass_env | while IFS= read -r -d '' kv; do
      v="${kv#*=}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
      printf '%s="%s"\n' "${kv%%=*}" "$v"
    done
  } | sudo tee "$RESUME_ENV" >/dev/null
  sudo chmod 600 "$RESUME_ENV"
  sudo tee "/etc/systemd/system/$RESUME_UNIT.service" >/dev/null <<EOF
[Unit]
Description=WidgetRAG bootstrap resume (NVIDIA 드라이버 재부팅 후 이어서 실행)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$(id -un)
EnvironmentFile=$RESUME_ENV
ExecStart=/bin/bash $TARGET_DIR/scripts/local/bootstrap.sh $MODE
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$RESUME_UNIT" >/dev/null
  log "재부팅합니다 — 부팅 완료 후 자동으로 이어서 진행됨 (수 분 뒤 재접속해 확인)"
  sudo reboot
  exit 0
fi

# 재개 유닛이 남아 있으면 다음 부팅부터 돌지 않도록 해제만 한다 (재부팅 경유로 여기 도달한 경우).
# ★ 여기서 유닛 파일을 지우거나 daemon-reload 하지 않는다 — 이 프로세스가 그 유닛 안에서 실행 중일 때
#   파일이 없는 채 reload 하면 systemd 가 유닛 설정(TimeoutStartSec=0)을 잃고 기본 90초 타임아웃으로
#   설치 도중 프로세스를 종료시킨다 (2026-10-16 T-002). 파일 정리는 맨 끝 cleanup_resume_unit 에서.
RESUME_CLEANUP=0
if [ -f "/etc/systemd/system/$RESUME_UNIT.service" ]; then
  log "자동 재개 — 다음 부팅부터 돌지 않도록 유닛 해제 (파일 정리는 완료 후)"
  sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
  RESUME_CLEANUP=1
fi

cleanup_resume_unit() {  # 모든 단계가 끝난 뒤 호출 — 유닛 파일 · 환경 파일(자격증명 포함 가능) 삭제
  [ "$RESUME_CLEANUP" = 1 ] || return 0
  sudo rm -f "/etc/systemd/system/$RESUME_UNIT.service" "$RESUME_ENV"
  if [ "${WIDGETRAG_RESUME:-0}" = 1 ] || [ -n "${INVOCATION_ID:-}" ]; then
    # 유닛 안에서 실행 중 — reload 하면 위 T-002 와 같은 이유로 종료된다. 다음 reload · 부팅 때 사라진다.
    log "재개 유닛 파일 정리 완료 (유닛 안에서 실행 중이라 daemon-reload 는 생략)"
  else
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$RESUME_UNIT" >/dev/null 2>&1 || true
    log "재개 유닛 파일 정리 완료"
  fi
}
if nvidia-smi >/dev/null 2>&1; then
  log "GPU 확인: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
fi

# ---------- 4. 실행 형태 진입 ----------
case "$MODE" in
  --install) "$TARGET_DIR/scripts/local/install.sh"
             log "준비 완료 (기동 전) — 기동: bootstrap.sh 또는 cd $TARGET_DIR/scripts/local && ./start.sh" ;;
  --start)   "$TARGET_DIR/scripts/local/install.sh"
             "$TARGET_DIR/scripts/local/start.sh" ;;
esac

# ---------- 5. 재개 유닛 파일 정리 (set -e 라 여기 도달하면 위 단계가 모두 성공한 것) ----------
cleanup_resume_unit
