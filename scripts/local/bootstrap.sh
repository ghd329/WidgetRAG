#!/usr/bin/env bash
# ===========================================================
# [부트스트랩] 신규 VM 진입점 — 코드 확보(git) + NVIDIA 드라이버 + 실행 형태 진입
#
#   최초 1회 (스크립트가 VM에 없는 상태 — postCommands 페이로드와 동일):
#
#     curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/main/scripts/local/bootstrap.sh \
#       | BRANCH=<브랜치> bash -s -- --start        # A: Shell 설치형 무인 기동 (B: --compose)
#
#   이후 (첫 실행이 자신을 /usr/local/bin/bootstrap.sh 로 설치하고, 브랜치는
#   기존 clone(~/WidgetRAG)에서 자동 유도하므로 짧게 친다):
#
#     bootstrap.sh --start        # 또는 --compose / --install
#
#   동작 순서 (멱등):
#     1) git 설치 → clone (있으면 fetch + reset --hard origin/BRANCH)
#     2) NVIDIA 드라이버 — GPU가 있는데 드라이버가 없으면 설치 후 재부팅.
#        ★ 재부팅 전에 systemd oneshot(widgetrag-bootstrap-resume)을 등록해두므로
#          부팅 후 같은 단계부터 자동 재개된다 — 사람이 다시 명령을 칠 필요 없음.
#          (클론을 드라이버보다 먼저 하는 이유: 재개 유닛이 디스크의 이 스크립트를 실행)
#     3) 자기 설치 — clone된 스크립트를 /usr/local/bin/bootstrap.sh 로 복사 (Linux, 멱등)
#     4) 실행 형태 진입:
#        --install : scripts/local/install.sh          (A: 도구 설치+설정, 기동 전까지)
#        --start   : install.sh → start.sh             (A: 기동+헬스체크까지)
#        --compose : scripts/compose/setup.sh          (B: Docker+toolkit+.env+up까지)
#        (없음)    : 코드·드라이버만 준비
#
#   환경변수:
#     REPO_URL   (기본 https://github.com/ghd329/WidgetRAG.git — public, 자격증명 불필요.
#                 Cloud-Barista Private 이전 시 deploy key/PAT 주입 방식 협의 필요)
#     BRANCH     (미지정 시: 기존 clone의 현재 브랜치 → 없으면 main) · COMMIT (해시 고정, 실증 재현성용)
#     TARGET_DIR (기본 $HOME/WidgetRAG)
#     NO_DRIVER=1  드라이버 단계 스킵 (GPU 없는 검증 VM 등)
#
#   재개 유닛 로그: sudo journalctl -u widgetrag-bootstrap-resume -f
# ===========================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/ghd329/WidgetRAG.git}"
BRANCH="${BRANCH:-}"          # 미지정 시: 기존 clone의 현재 브랜치 → 없으면 main
COMMIT="${COMMIT:-}"
TARGET_DIR="${TARGET_DIR:-$HOME/WidgetRAG}"
MODE="${1:-}"
RESUME_UNIT="widgetrag-bootstrap-resume"

log() { printf '\033[1;32m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[bootstrap][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

case "$MODE" in ""|--install|--start|--compose) : ;; *) die "알 수 없는 옵션: $MODE (--install | --start | --compose)" ;; esac

# ---------- 1. 코드 확보 ----------
if ! command -v git >/dev/null 2>&1; then
  log "git 설치 (apt)"
  sudo apt-get update -y && sudo apt-get install -y git
fi

if [ -d "$TARGET_DIR/.git" ]; then
  if [ -z "$BRANCH" ]; then
    # 기존 clone의 브랜치를 그대로 따라간다 — 짧은 재실행(bootstrap.sh --start)의 핵심
    BRANCH="$(git -C "$TARGET_DIR" symbolic-ref --short -q HEAD || true)"
  fi
  if [ -z "$BRANCH" ]; then
    log "기존 저장소가 커밋 고정(detached) 상태 — 갱신 없이 현재 코드로 진행 (갱신하려면 BRANCH= 지정)"
  else
    log "기존 저장소 갱신: $TARGET_DIR (origin/$BRANCH 기준으로 동기화)"
    git -C "$TARGET_DIR" fetch origin
    git -C "$TARGET_DIR" checkout "$BRANCH"
    git -C "$TARGET_DIR" reset --hard "origin/$BRANCH"
  fi
else
  BRANCH="${BRANCH:-main}"
  # rsync 시절 사본 등 git 저장소가 아닌 디렉토리가 있으면 백업 후 clone
  # (저장소 디렉토리의 내용물은 전부 재생성 가능 — 운영 데이터는 ~/widgetrag-data에 별도)
  if [ -e "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    BAK="$TARGET_DIR.bak.$(date +%Y%m%d%H%M%S)"
    log "비-git 디렉토리 발견 (rsync 사본 등) — 백업 후 clone: $TARGET_DIR → $BAK"
    mv "$TARGET_DIR" "$BAK"
  fi
  log "clone: $REPO_URL ($BRANCH) → $TARGET_DIR"
  git clone -b "$BRANCH" "$REPO_URL" "$TARGET_DIR"
fi
[ -n "$COMMIT" ] && { log "커밋 고정: $COMMIT"; git -C "$TARGET_DIR" checkout --quiet "$COMMIT"; }
log "코드 준비 완료: $(git -C "$TARGET_DIR" rev-parse --short HEAD) (요청: ${COMMIT:-${BRANCH:-현재 커밋}})"

# ---------- 1.5 자기 설치 — 이후에는 어디서든 `bootstrap.sh --start` 로 호출 ----------
if [ "$(uname -s)" = "Linux" ]; then
  if ! cmp -s "$TARGET_DIR/scripts/local/bootstrap.sh" /usr/local/bin/bootstrap.sh 2>/dev/null; then
    sudo install -m 755 "$TARGET_DIR/scripts/local/bootstrap.sh" /usr/local/bin/bootstrap.sh
    log "커맨드 설치: /usr/local/bin/bootstrap.sh — 다음부터는 'bootstrap.sh --start' 로 실행"
  fi
fi

# ---------- 2. NVIDIA 드라이버 (Linux + GPU 존재 시) ----------
need_driver() {
  [ "${NO_DRIVER:-}" = "1" ] && return 1
  [ "$(uname -s)" = "Linux" ] || return 1
  nvidia-smi >/dev/null 2>&1 && return 1          # 이미 동작
  command -v lspci >/dev/null 2>&1 || sudo apt-get install -y pciutils >/dev/null 2>&1 || true
  lspci 2>/dev/null | grep -qi nvidia              # NVIDIA GPU가 실재할 때만
}

if need_driver; then
  log "NVIDIA 드라이버 설치 (GPU 감지됨, 드라이버 미동작) — 설치 후 재부팅·자동 재개"
  sudo apt-get update -y && sudo apt-get install -y ubuntu-drivers-common
  sudo ubuntu-drivers install

  log "재부팅 후 자동 재개 유닛 등록: $RESUME_UNIT (로그: sudo journalctl -u $RESUME_UNIT -f)"
  sudo tee "/etc/systemd/system/$RESUME_UNIT.service" >/dev/null <<EOF
[Unit]
Description=WidgetRAG bootstrap resume (NVIDIA 드라이버 재부팅 후 이어서 실행)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$USER
Environment=REPO_URL=$REPO_URL
Environment=BRANCH=$BRANCH
Environment=COMMIT=$COMMIT
Environment=TARGET_DIR=$TARGET_DIR
Environment=HOME=$HOME
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
  sudo rm -f "/etc/systemd/system/$RESUME_UNIT.service"
  sudo systemctl daemon-reload
fi
if [ "$(uname -s)" = "Linux" ] && nvidia-smi >/dev/null 2>&1; then
  log "GPU 확인: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
fi

# ---------- 3. 실행 형태 진입 ----------
case "$MODE" in
  "")        log "코드·드라이버 준비 완료 — A: --install/--start · B: --compose" ;;
  --install) "$TARGET_DIR/scripts/local/install.sh" ;;
  --start)   "$TARGET_DIR/scripts/local/install.sh"
             "$TARGET_DIR/scripts/local/start.sh" ;;
  --compose) "$TARGET_DIR/scripts/compose/setup.sh" ;;
esac
