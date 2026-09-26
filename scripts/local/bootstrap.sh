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
#        ★ curl | bash 로 들어오면 스크립트 본문이 stdin 이다. 뒤에서 stdin 을 읽는 명령이 돌면
#          남은 본문을 삼켜 에러 한 줄 없이 끝난다 (LexAI 결함 4). 사본으로 갈아타 stdin 과 끊는다.
#     2) 자기 설치 — clone된 스크립트를 /usr/local/bin/bootstrap.sh 로 복사
#     3) NVIDIA 드라이버 — GPU가 있는데 드라이버가 없으면 설치 후 재부팅.
#        재부팅 전에 systemd oneshot(widgetrag-bootstrap-resume)을 등록해 같은 단계부터 자동 재개.
#        curl | bash 앞에 붙인 환경변수(SNAPSHOT_URI 등)는 재부팅 뒤에 사라지므로 함께 넘긴다.
#     4) 실행 형태 진입
#        --start   : install.sh → start.sh (인프라 → 패키지 복원 → 앱 → 검증)  ← 기본
#        --install : install.sh            (도구 설치 + 설정, 기동 전까지)
#
#   환경변수 (전부 선택)
#     REPO_URL      기본 https://github.com/ghd329/WidgetRAG.git — public, 자격증명 불필요
#                   (Cloud-Barista Private 이전 시 deploy key/PAT 주입 방식 협의 필요)
#     BRANCH        미지정 시 기존 clone 의 현재 브랜치 → 없으면 feat/20260922-change-sqlite
#     COMMIT        해시 고정 (실증 재현성용)
#     TARGET_DIR    기본 $HOME/WidgetRAG
#     TARGET_USER   root 로 실행될 때 서비스를 돌릴 사용자 (기본 uid 1000)
#     SNAPSHOT_URI  이관 패키지 위치 (s3:// · gs:// · https:// · 로컬 경로) — scripts/package.sh
#     NO_DRIVER=1   드라이버 단계 스킵 (GPU 이미지 · GPU 없는 검증 VM)
#     NO_START=1    준비만 하고 기동은 안 함 (= --install)
#
#   재개 유닛 로그: sudo journalctl -u widgetrag-bootstrap-resume -f
# ===========================================================
set -euo pipefail

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춘다.
export DEBIAN_FRONTEND=noninteractive
# 비대화형 실행(원격 커맨드 · systemd)에서 HOME 이 비어 있을 수 있다 — 계정 정보에서 채운다
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"

DEFAULT_BRANCH="feat/20260922-change-sqlite"
REPO_URL="${REPO_URL:-https://github.com/ghd329/WidgetRAG.git}"
BRANCH="${BRANCH:-}"          # 미지정 시: 기존 clone의 현재 브랜치 → 없으면 DEFAULT_BRANCH
COMMIT="${COMMIT:-}"
MODE="${1:-}"
RESUME_UNIT="widgetrag-bootstrap-resume"
RESUME_ENV="/etc/widgetrag/bootstrap-resume.env"

# 재실행 · 재부팅 재개 때 넘겨야 하는 값 — 설정된 것만 넘긴다
PASS_VARS=(REPO_URL BRANCH COMMIT TARGET_DIR SNAPSHOT_URI S3_ENDPOINT_URL NO_DRIVER FORCE_RESTORE
           LLM_TEMPERATURE LLM_SEED APP_TZ OLLAMA_MODEL FORM RUNS REQUIRE_DATA VERIFY_ADMIN_PASSWORD
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
    [ -n "${!v:-}" ] && printf '%s\0' "$v=${!v}"
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

# ---------- 0. 실행 사용자 — root 면 uid 1000 사용자로 이어서 ----------
if [ "$(id -u)" -eq 0 ] && [ "${WIDGETRAG_REEXEC:-0}" != 1 ]; then
  RUN_USER="${TARGET_USER:-${SUDO_USER:-}}"
  if [ -z "$RUN_USER" ] || [ "$RUN_USER" = root ]; then
    RUN_USER="$( { getent passwd 1000 | cut -d: -f1; } || true )"
  fi
  [ -n "$RUN_USER" ] || die "일반 사용자를 찾지 못했습니다 — TARGET_USER 로 지정하세요"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  TARGET_DIR="${TARGET_DIR:-$RUN_HOME/WidgetRAG}"
  log "root 로 실행되었습니다 — ${RUN_USER} 사용자로 이어서 진행합니다"

  ensure_git
  # 재실행할 스크립트가 디스크에 있어야 한다 — 저장소를 그 사용자로 받는다 (root 가 받으면
  # 소유자가 달라 이후 git 이 dubious ownership 으로 거부한다)
  sync_repo sudo -u "$RUN_USER" -H
  mapfile -d '' ENV_ARGS < <(pass_env)
  exec sudo -u "$RUN_USER" -H env WIDGETRAG_REEXEC=1 WIDGETRAG_FROMFILE=1 "${ENV_ARGS[@]}" \
    TARGET_DIR="$TARGET_DIR" BRANCH="$BRANCH" \
    bash "$TARGET_DIR/scripts/local/bootstrap.sh" "$MODE" </dev/null
fi

TARGET_DIR="${TARGET_DIR:-$HOME/WidgetRAG}"

# ---------- 1. 코드 확보 → 디스크 사본으로 다시 실행 ----------
if [ "${WIDGETRAG_FROMFILE:-0}" != 1 ]; then
  ensure_git
  sync_repo
  # 사본에서 실행 중일 때(WIDGETRAG_FROMFILE=1)는 저장소를 건드리지 않는다 — bash 는 스크립트를
  # 조금씩 읽어가므로, 실행 중인 파일을 git 이 덮어쓰면 남은 부분이 깨진다.
  export WIDGETRAG_FROMFILE=1 REPO_URL BRANCH COMMIT TARGET_DIR
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

if need_driver; then
  log "NVIDIA 드라이버 설치 (GPU 감지됨, 드라이버 미동작) — 설치 후 재부팅·자동 재개"
  apt_get update -qq && apt_get install -y -q ubuntu-drivers-common
  sudo ubuntu-drivers install

  # ★ 재부팅 뒤에는 환경이 새로 시작된다. curl | bash 앞에 붙인 변수(SNAPSHOT_URI 등)는
  #   여기 적어두지 않으면 사라진다 (LexAI 에서 ALLOW_EMPTY_INDEX 가 유실된 결함과 같은 계열).
  #   자격증명이 섞일 수 있어 유닛 파일(644)이 아니라 root 600 환경 파일에 둔다.
  log "재부팅 후 자동 재개 유닛 등록: $RESUME_UNIT (로그: sudo journalctl -u $RESUME_UNIT -f)"
  sudo install -d -m 755 "$(dirname "$RESUME_ENV")"
  {
    echo "HOME=$HOME"
    echo "WIDGETRAG_FROMFILE=1"
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

# 재개 유닛이 남아 있으면 정리 (재부팅 경유로 여기 도달한 경우)
if [ -f "/etc/systemd/system/$RESUME_UNIT.service" ]; then
  log "자동 재개 완료 — 재개 유닛 정리"
  sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
  sudo rm -f "/etc/systemd/system/$RESUME_UNIT.service" "$RESUME_ENV"
  sudo systemctl daemon-reload
fi
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
