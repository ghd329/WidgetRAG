#!/usr/bin/env bash
# ===========================================================
# WidgetRAG — Docker Compose(B) 타겟 배포 — 사람이 하는 일은 VM 생성과 SSH 접속까지
#
#   curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/compose/deploy.sh | bash
#
#   이 한 줄이 드라이버 · Docker · 이미지 기동 · 데이터 복원 · 검증을 무인으로 수행한다
#   (postCommands 페이로드와 동일 — LexAI deploy/compose/deploy.sh 와 같은 방식).
#   이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주면 색인 · DB 까지 복원한다:
#
#     curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/<시각> bash
#
#   ★ 저장소와 독립적으로 동작한다 — 타겟에 git 도 소스도 필요 없다. 이미지가 곧 산출물이고,
#     저장소에서 raw 로 받는 것은 아래 4개가 전부다 (Shell 설치형 bootstrap.sh 가 clone 해서
#     빌드하는 것과 대비되는 지점).
#       docker-compose.yml · docker-compose.images.yml   compose 정의 (build: 는 오버레이가 지움)
#       package.sh · verify.sh                            이관 패키지 복원 · 합격 기준 검증 (두 형태 공용)
#
#   수행 내용 (멱등 — 재실행하면 이미 끝난 단계는 건너뛴다)
#     0) root 로 실행되면 uid 1000 사용자로, 파이프로 들어오면 디스크 사본으로 다시 실행
#        (curl | bash 에서 docker compose exec 등이 stdin 을 읽어 남은 본문을 삼키는 문제 — LexAI 결함 4)
#     1) 기본 도구 (curl · sqlite3 · pigz …)
#     2) NVIDIA 드라이버 — 없으면 설치 후 재부팅, 부팅이 끝나면 같은 지점부터 자동 재개
#     3) Docker 엔진 + Compose v2.24+ + nvidia-container-toolkit → 컨테이너 GPU 통과 확인
#     4) 배포 파일 수신 · .env 생성(관리자 비밀번호 무작위 발급)
#     5) 이미지 pull → SNAPSHOT_URI 가 있으면 패키지 수신 → 앱보다 먼저 DB · 색인 복원 → 전체 기동
#     6) 합격 기준 검증 (verify.sh — Shell 설치형과 같은 판정 · 같은 결과표)
#
#   환경변수 (전부 선택 — 기본값으로 무인 실행 가능)
#     REGISTRY_PREFIX 이미지 레지스트리 주소/계정 (기본 yjp8842 = Docker Hub)
#                     ECR: <계정ID>.dkr.ecr.<리전>.amazonaws.com · GAR: <리전>-docker.pkg.dev/<프로젝트>/<저장소>
#                     NCR: <레지스트리>.kr.ncr.ntruss.com — 프라이빗 레지스트리는 docker login 선행
#     IMAGE_TAG       이미지 태그 (기본 v0.3.0 — FK 강제까지 반영, 고정 태그만·latest 금지)
#     BRANCH          배포 파일을 받아올 브랜치/태그 (기본 feat/20260922-change-sqlite)
#     REPO_RAW        배포 파일의 raw 주소 (기본 https://raw.githubusercontent.com/ghd329/WidgetRAG — 포크·미러용)
#     WORK_DIR        배포 디렉토리 (기본 ~/widgetrag-deploy)
#     SNAPSHOT_URI    이관 패키지 위치 (s3:// · gs:// · https:// · 로컬 경로) — scripts/package.sh
#     FORCE_RESTORE=1 DB · 색인이 이미 있어도 패키지로 덮어씀 (기본은 건너뜀)
#     LLM_TEMPERATURE · LLM_SEED   동등성 비교용 결정적 설정 (예: 0 · 42) — .env 에 반영
#     TARGET_USER     root 로 실행될 때 배포할 사용자 (기본 uid 1000)
#     NO_DRIVER=1     드라이버 단계 건너뜀 (GPU 이미지 · GPU 없는 검증 VM)
#     NO_START=1      준비만 하고 기동은 안 함
#     SKIP_VERIFY=1   마지막 검증을 건너뜀
#
#   기동 후: 모델(gemma3:4b, 약 3.3GB)은 llm 컨테이너가 자동 pull — 최초 수 분 소요.
#   재부팅 재개 로그: sudo journalctl -u widgetrag-compose-resume -f
# ===========================================================
set -euo pipefail

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춘다.
export DEBIAN_FRONTEND=noninteractive
# 비대화형 실행(원격 커맨드 · systemd)에서 HOME 이 비어 있을 수 있다 — 계정 정보에서 채운다
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"

BRANCH="${BRANCH:-feat/20260922-change-sqlite}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/ghd329/WidgetRAG}"   # 포크 · 사내 미러면 바꾼다
RAW_BASE="$REPO_RAW/$BRANCH"
SELF_URL="$RAW_BASE/scripts/compose/deploy.sh"
RESUME_UNIT="widgetrag-compose-resume"
RESUME_ENV="/etc/widgetrag/compose-resume.env"

# 재실행 · 재부팅 재개 때 넘겨야 하는 값 — 사람이 지정한 것만 넘긴다 (기본값 적용 전에 판단)
PASS_VARS=(BRANCH REPO_RAW WORK_DIR REGISTRY_PREFIX IMAGE_TAG SNAPSHOT_URI S3_ENDPOINT_URL FORCE_RESTORE NO_DRIVER
           NO_START SKIP_VERIFY LLM_TEMPERATURE LLM_SEED FORM RUNS VERIFY_ADMIN_PASSWORD
           AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION)

# 이관 도구로 실행되면 TTY 가 없고 출력이 로그로 수집된다 — 그때는 색상 제어문자를 쓰지 않는다.
if [ -t 1 ]; then
  log()  { printf '\033[1;32m[compose-deploy]\033[0m %s\n' "$*"; }
  warn() { printf '\033[1;33m[compose-deploy][WARN]\033[0m %s\n' "$*"; }
  die()  { printf '\033[1;31m[compose-deploy][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
else
  log()  { printf '[compose-deploy] %s\n' "$*"; }
  warn() { printf '[compose-deploy][WARN] %s\n' "$*"; }
  die()  { printf '[compose-deploy][FAIL] %s\n' "$*" >&2; exit 1; }
fi

[ "$(uname -s)" = "Linux" ] || die "타겟 VM(Ubuntu Linux) 전용 스크립트입니다"

apt_get() {  # apt_get <인자...> — sudo 가 DEBIAN_FRONTEND 를 지우므로 env 로 명시 전달
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
fetch_self() {  # fetch_self <대상 파일> [사용자] — 최신 사본을 받아 원자적으로 교체
  local dst="$1" as=()
  [ -n "${2:-}" ] && as=(sudo -u "$2" -H)
  "${as[@]}" mkdir -p "$(dirname "$dst")"
  if "${as[@]}" curl -fsSL "$SELF_URL" -o "$dst.new"; then
    "${as[@]}" mv "$dst.new" "$dst"
    "${as[@]}" chmod +x "$dst"
  else
    "${as[@]}" rm -f "$dst.new"
    [ -f "$dst" ] || die "스크립트를 받지 못했습니다: $SELF_URL"
    warn "최신본을 받지 못해 기존 사본을 씁니다: $dst"
  fi
}

# 배포 디렉토리의 사본을 직접 실행한 경우(bash ~/어딘가/deploy.sh)는 그 디렉토리를 쓴다 —
# 기본값으로 가면 다른 배포 디렉토리를 덮어쓴다 (재기동 안내가 "bash <배포디렉토리>/deploy.sh" 다).
if [ -z "${WORK_DIR:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ] \
   && [ -f "$(dirname "${BASH_SOURCE[0]}")/docker-compose.yml" ]; then
  WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------- 0-1. 실행 사용자 — root 면 uid 1000 사용자로 이어서 ----------
# root 로 그대로 진행하면 배포 디렉토리와 .env 가 /root 아래에 생겨, 나중에 사람이 SSH 로
# 붙었을 때 아무것도 보이지 않는다 (scripts/local/bootstrap.sh 와 같은 방식).
if [ "$(id -u)" -eq 0 ] && [ "${WIDGETRAG_REEXEC:-0}" != 1 ]; then
  RUN_USER="${TARGET_USER:-${SUDO_USER:-}}"
  if [ -z "$RUN_USER" ] || [ "$RUN_USER" = root ]; then
    RUN_USER="$( { getent passwd 1000 | cut -d: -f1; } || true )"
  fi
  [ -n "$RUN_USER" ] || die "일반 사용자를 찾지 못했습니다 — TARGET_USER 로 지정하세요"
  RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  WORK_DIR="${WORK_DIR:-$RUN_HOME/widgetrag-deploy}"
  log "root 로 실행되었습니다 — ${RUN_USER} 사용자로 이어서 진행합니다"
  command -v curl >/dev/null 2>&1 || { apt_get update -qq; apt_get install -y -q curl ca-certificates; }
  fetch_self "$WORK_DIR/deploy.sh" "$RUN_USER"
  mapfile -d '' ENV_ARGS < <(pass_env)
  exec sudo -u "$RUN_USER" -H env WIDGETRAG_REEXEC=1 WIDGETRAG_FROMFILE=1 "${ENV_ARGS[@]}" \
    WORK_DIR="$WORK_DIR" bash "$WORK_DIR/deploy.sh" "$@" </dev/null
fi

WORK_DIR="${WORK_DIR:-$HOME/widgetrag-deploy}"

# ---------- 0-2. 디스크 사본으로 다시 실행 ----------
# curl | bash 로 들어오면 스크립트 본문 자체가 stdin 이다. 뒤에서 docker compose exec 처럼
# stdin 을 읽는 명령이 돌면 아직 읽지 않은 본문을 통째로 삼키고, bash 는 EOF 를 만나 종료코드 0
# 으로 조용히 끝난다 (LexAI 결함 4 — 색인 복원이 사라졌다). 사본으로 갈아타 stdin 과 끊는다.
# 사본은 매번 새로 받는다 — "없을 때만" 받으면 옛 사본이 계속 실행되어 고친 내용이 반영되지 않는다.
# (로컬에서 고친 사본을 그대로 돌리려면 NO_SELF_UPDATE=1)
if [ "${WIDGETRAG_FROMFILE:-0}" != 1 ]; then
  if [ "${NO_SELF_UPDATE:-0}" = 1 ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  else
    command -v curl >/dev/null 2>&1 || { apt_get update -qq; apt_get install -y -q curl ca-certificates; }
    fetch_self "$WORK_DIR/deploy.sh"
    SELF="$WORK_DIR/deploy.sh"
  fi
  export WIDGETRAG_FROMFILE=1 BRANCH REPO_RAW WORK_DIR
  exec bash "$SELF" "$@" </dev/null
fi

# 명시 지정 여부를 기본값 적용 전에 기억 — 재실행 시 기존 .env에 그 값만 갱신하기 위함
REGISTRY_PREFIX_ARG="${REGISTRY_PREFIX:-}"
IMAGE_TAG_ARG="${IMAGE_TAG:-}"
LLM_TEMPERATURE_ARG="${LLM_TEMPERATURE:-}"
LLM_SEED_ARG="${LLM_SEED:-}"
mapfile -d '' RESUME_ARGS < <(pass_env)       # 재부팅 재개에 넘길 값 (기본값 적용 전)
REGISTRY_PREFIX="${REGISTRY_PREFIX:-yjp8842}"
IMAGE_TAG="${IMAGE_TAG:-v0.3.0}"
PACKAGE_DIR="$WORK_DIR/package"
TOTAL_START=$(date +%s)

# ---------- 1. 기본 도구 ----------
# sqlite3 — 볼륨 안 DB 복원·검증 · pigz — 이관 패키지 병렬 압축 · python3 — JSON 판정
need=""
for c in curl openssl sqlite3 pigz python3 gpg; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
  log "기본 도구 설치:$need"
  apt_get update -qq
  apt_get install -y -q curl ca-certificates openssl sqlite3 pigz python3 gnupg >/dev/null
fi

# ---------- 2. NVIDIA 드라이버 (GPU 있고 미설치면) ----------
need_driver() {
  [ "${NO_DRIVER:-}" = "1" ] && return 1
  nvidia-smi >/dev/null 2>&1 && return 1
  command -v lspci >/dev/null 2>&1 || apt_get install -y -q pciutils >/dev/null 2>&1 || true
  lspci 2>/dev/null | grep -qi nvidia
}
if need_driver; then
  log "NVIDIA GPU 감지, 드라이버 미동작 — 설치 후 재부팅·자동 재개"
  apt_get update -qq && apt_get install -y -q ubuntu-drivers-common
  sudo ubuntu-drivers install

  # ★ 재부팅 뒤에는 환경이 새로 시작된다. curl | bash 앞에 붙인 변수(SNAPSHOT_URI 등)는 여기 적어두지
  #   않으면 사라진다. 자격증명이 섞일 수 있어 유닛 파일(644)이 아니라 root 600 환경 파일에 둔다.
  sudo install -d -m 755 "$(dirname "$RESUME_ENV")"
  {
    echo "HOME=$HOME"
    echo "WIDGETRAG_FROMFILE=1"
    echo "WORK_DIR=$WORK_DIR"
    for kv in "${RESUME_ARGS[@]}"; do
      v="${kv#*=}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
      printf '%s="%s"\n' "${kv%%=*}" "$v"
    done
  } | sudo tee "$RESUME_ENV" >/dev/null
  sudo chmod 600 "$RESUME_ENV"
  sudo tee "/etc/systemd/system/$RESUME_UNIT.service" >/dev/null <<EOF
[Unit]
Description=WidgetRAG compose deploy resume (드라이버 재부팅 후 이어서 실행)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$(id -un)
EnvironmentFile=$RESUME_ENV
ExecStart=/bin/bash $WORK_DIR/deploy.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$RESUME_UNIT" >/dev/null
  log "재부팅합니다 — 진행 확인: sudo journalctl -u $RESUME_UNIT -f"
  sleep 3
  sudo reboot
  exit 0
fi
if [ -f "/etc/systemd/system/$RESUME_UNIT.service" ]; then
  log "재부팅 후 자동 재개 — 재개 유닛 정리"
  sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
  sudo rm -f "/etc/systemd/system/$RESUME_UNIT.service" "$RESUME_ENV"
  sudo systemctl daemon-reload
fi
nvidia-smi >/dev/null 2>&1 && log "GPU 확인: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"

# ---------- 3. Docker 엔진 + nvidia-container-toolkit ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker 설치 (공식 스크립트)"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$(id -un)"
  log "docker 그룹 등록 — 재로그인 후 sudo 없이 사용 가능 (지금은 sudo로 계속 진행)"
fi
# 방금 그룹에 추가된 경우 현재 셸에는 아직 반영되지 않는다 — 그때는 sudo 로 우회
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
$DOCKER info >/dev/null 2>&1 || die "Docker 데몬에 연결 불가"

# docker-compose.images.yml 의 build: !reset null 은 v2.24+ 문법이다. 낮은 버전이면 본체의
# build: 가 살아남아 소스 없는 환경에서 빌드를 시도한다.
CVER="$($DOCKER compose version --short 2>/dev/null || echo 0)"; CVER="${CVER#v}"
CMAJOR="${CVER%%.*}"; CREST="${CVER#*.}"; CMINOR="${CREST%%.*}"
if [ "${CMAJOR:-0}" -lt 2 ] 2>/dev/null || { [ "${CMAJOR:-0}" -eq 2 ] && [ "${CMINOR:-0}" -lt 24 ]; }; then
  die "Docker Compose ${CVER} 는 너무 낮습니다 — v2.24 이상 필요 (build: !reset)"
fi
log "Docker Compose v$CVER"

if nvidia-smi >/dev/null 2>&1; then
  if ! $DOCKER info 2>/dev/null | grep -qi nvidia; then
    log "nvidia-container-toolkit 설치 (compose의 GPU 예약에 필수)"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
      sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    apt_get update -qq && apt_get install -y -q nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
  fi
  # toolkit 이 없거나 설정이 틀리면 에러 없이 CPU 로 폴백해 응답만 느려진다 — 증상이 늦게,
  # 엉뚱한 곳에서 드러나므로 매번 실제 컨테이너를 띄워 확인한다.
  GPU="$($DOCKER run --rm --gpus all ubuntu:24.04 nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)" \
    || die "컨테이너에서 GPU 미인식 — toolkit 구성 확인 ($DOCKER info | grep -i nvidia)"
  log "컨테이너 GPU 통과 확인: $GPU"
else
  warn "GPU 미감지 — toolkit 생략 (GPU 예약 서비스는 기동 실패할 수 있음, EMBEDDING_DEVICE=cpu로 진행)"
fi

# ---------- 4. 배포 파일 수신 (저장소에서 받는 전부 — git·소스 없음) ----------
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
log "배포 파일 수신: $RAW_BASE ($BRANCH)"
curl -fsSL "$RAW_BASE/docker-compose.yml"        -o docker-compose.yml        || die "docker-compose.yml 수신 실패"
curl -fsSL "$RAW_BASE/docker-compose.images.yml" -o docker-compose.images.yml || die "docker-compose.images.yml 수신 실패"
curl -fsSL "$RAW_BASE/scripts/package.sh"        -o package.sh                || die "package.sh 수신 실패"
curl -fsSL "$RAW_BASE/scripts/verify.sh"         -o verify.sh                 || die "verify.sh 수신 실패"
chmod +x package.sh verify.sh
# caddy 는 구성에서 뺐다 (frontend 의 nginx 가 /api 를 프록시) — 예전 배포가 남긴 파일은 치운다
if [ -e Caddyfile ]; then sudo rm -rf Caddyfile; log "구성 축소 — 예전 Caddyfile 제거 (caddy 서비스 삭제됨)"; fi

# 색인 스냅샷 저장소 (opensearch 의 /mnt/snapshots) — 컨테이너의 opensearch(uid 1000)가 써야 한다.
# 없으면 도커가 root 소유 디렉토리로 만들어 저장소 등록이 거부된다.
mkdir -p snapshots
sudo chown 1000:1000 snapshots

# ---------- 5. .env 생성 (없으면 — 무인 검증 기본값) ----------
env_get() { { grep "^$1=" .env | tail -1 | cut -d= -f2- ; } || true; }   # 같은 키는 마지막 값 우선 — compose 와 같은 규칙
if [ -f .env ]; then
  # 기존 .env 유지 — 단, 이번 실행에서 명시 지정한 값은 갱신한다
  # (안 그러면 IMAGE_TAG=v0.4.0 지정이 기존 .env의 옛 값에 조용히 밀리는 함정)
  for kv in "REGISTRY_PREFIX=$REGISTRY_PREFIX_ARG" "IMAGE_TAG=$IMAGE_TAG_ARG" \
            "LLM_TEMPERATURE=$LLM_TEMPERATURE_ARG" "LLM_SEED=$LLM_SEED_ARG"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$v" ] || continue
    if grep -q "^$k=" .env; then sed -i "s|^$k=.*|$k=$v|" .env; else echo "$k=$v" >> .env; fi
    log ".env 갱신: $k=$v (명시 지정)"
  done
  log ".env 유지 — 적용값: REGISTRY_PREFIX=$(env_get REGISTRY_PREFIX) IMAGE_TAG=$(env_get IMAGE_TAG)"
else
  EMBED_DEV="$(nvidia-smi >/dev/null 2>&1 && echo cuda || echo cpu)"
  log ".env 생성 (관리자 비밀번호 무작위 발급, EMBEDDING_DEVICE=$EMBED_DEV)"
  cat > .env <<EOF
# scripts/compose/deploy.sh 가 생성 — 무인 검증 기본값
ADMIN_EMAIL=admin@widgetrag.com
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
# 브라우저는 SSH 터널(-L 8081:localhost:80)로 접속한다 — Shell 설치형과 같은 터널·같은 오리진
PUBLIC_BASE_URL=http://localhost:8081
CORS_ALLOWED_ORIGINS=http://localhost:8081,http://127.0.0.1:8081
SESSION_SECURE=false
SESSION_SAME_SITE=lax
EMBEDDING_DEVICE=$EMBED_DEV
OLLAMA_MODEL=gemma3:4b
# 이관 전후 동등성 비교용 결정적 설정 (평소 운영 0.7 · 빈 값)
LLM_TEMPERATURE=${LLM_TEMPERATURE_ARG:-0.7}
LLM_SEED=${LLM_SEED_ARG}
# 엔티티 시각(LocalDateTime.now)의 기준 — Shell 설치형과 같은 값
TZ=Asia/Seoul
REGISTRY_PREFIX=$REGISTRY_PREFIX
IMAGE_TAG=$IMAGE_TAG
EOF
  chmod 600 .env
  log "관리자 비밀번호는 .env에서 확인: grep ADMIN_PASSWORD $WORK_DIR/.env"
fi

dc() { $DOCKER compose -f docker-compose.yml -f docker-compose.images.yml "$@"; }
# ★ exec 에는 </dev/null — docker compose exec 는 -T 여도 stdin 을 읽는다
healthy()     { [ "$(dc ps --format '{{.Health}}' "$1" 2>/dev/null)" = healthy ]; }
model_ready() { dc exec -T llm ollama list </dev/null 2>/dev/null | awk '{print $1}' | grep -Fqx "$OLLAMA_MODEL"; }
ai_ready()    { dc exec -T ai-server python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/docs')" </dev/null; }
front_ready() { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1/login/company-login.html"; }
wait_until() {  # wait_until <설명> <최대초> <명령...>
  local label="$1" timeout="$2" waited=0
  shift 2
  printf '[compose-deploy] %s 대기' "$label"
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$timeout" ]; then printf '\n'; return 1; fi
    sleep 10; waited=$((waited + 10)); printf '.'
  done
  printf ' (%ss)\n' "$waited"
}

if [ "${NO_START:-0}" = 1 ]; then
  log "준비 완료 (NO_START=1 — 기동은 하지 않았습니다)"
  echo "  기동: bash $WORK_DIR/deploy.sh"
  exit 0
fi

# ---------- 6. 레지스트리 이미지 기동 (빌드 없음) — 복원은 앱보다 먼저 ----------
log "이미지 pull: $(env_get REGISTRY_PREFIX)/widgetrag:*-$(env_get IMAGE_TAG)"
dc pull

if [ -n "${SNAPSHOT_URI:-}" ]; then
  bash ./package.sh fetch "$SNAPSHOT_URI" "$PACKAGE_DIR"
fi
HAS_PACKAGE=0
[ -f "$PACKAGE_DIR/checksums.sha256" ] && HAS_PACKAGE=1

# 컨테이너 · 볼륨만 먼저 만든다. backend 는 기동하면서 빈 DB(+관리자)와 빈 색인을 만들기 때문에,
# 패키지는 그보다 먼저 볼륨에 넣어야 한다 — 네이티브 형태의 35-restore-package.sh 와 같은 순서.
# --remove-orphans: 예전 구성의 caddy 컨테이너가 80 을 잡고 있으면 frontend 가 뜨지 못한다.
dc up --no-start --no-build --remove-orphans
if [ "$HAS_PACKAGE" = 1 ]; then
  if [ "${FORCE_RESTORE:-0}" = 1 ]; then dc stop backend >/dev/null 2>&1 || true; fi
  RUNTIME=compose COMPOSE_DIR="$WORK_DIR" bash ./package.sh restore "$PACKAGE_DIR" data
fi

log "opensearch 기동"
dc up -d --no-build opensearch
wait_until "opensearch healthy" 300 healthy opensearch \
  || die "opensearch 가 준비되지 않았습니다 — docker compose logs opensearch"
if [ "$HAS_PACKAGE" = 1 ]; then
  RUNTIME=compose COMPOSE_DIR="$WORK_DIR" bash ./package.sh restore "$PACKAGE_DIR" index
fi

log "전체 기동 (up -d --no-build)"
dc up -d --no-build --remove-orphans

# 최초 기동은 모델 pull(3.3GB) · 임베딩 모델 다운로드(2.3GB)로 수 분 걸린다
OLLAMA_MODEL="$(env_get OLLAMA_MODEL)"; OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:4b}"
wait_until "backend healthy" 600 healthy backend \
  || warn "backend 가 600초 안에 healthy 가 되지 않음 — docker compose logs backend"
wait_until "LLM 모델($OLLAMA_MODEL) 적재" 900 model_ready \
  || warn "모델이 900초 안에 준비되지 않음 — docker compose logs llm"
wait_until "AI 서버(임베딩 모델 로드)" 900 ai_ready \
  || warn "AI 서버가 900초 안에 응답하지 않음 — docker compose logs ai-server"
wait_until "진입점(frontend :80)" 120 front_ready \
  || warn "frontend 가 응답하지 않음 — docker compose logs frontend"
echo
dc ps

# ---------- 7. 합격 기준 검증 (Shell 설치형과 같은 판정 · 같은 결과표) ----------
VERIFY_RESULT="건너뜀"
if [ "${SKIP_VERIFY:-0}" != 1 ]; then
  echo
  if [ -f "$PACKAGE_DIR/.restored" ]; then export REQUIRE_DATA="${REQUIRE_DATA:-1}"; fi
  if RUNTIME=compose COMPOSE_DIR="$WORK_DIR" bash ./verify.sh; then VERIFY_RESULT=PASS; else VERIFY_RESULT=FAIL; fi
fi

echo
log "완료 ($(( $(date +%s) - TOTAL_START ))초) — 타겟에 있는 것: deploy.sh · compose 2개 · package.sh · verify.sh · .env · 컨테이너 (소스·git 없음)"
echo "  검증 결과         : $VERIFY_RESULT  (누적: ~/widgetrag-run/results.csv)"
echo "  [로컬 PC] 터널    : ssh -N -L 8081:localhost:80 ubuntu@<타겟IP>   (이후 로컬 브라우저로 접속)"
echo "  콘솔(가입/로그인) : http://localhost:8081/login/company-signup.html"
echo "  데모샵(위젯)      : http://localhost:8081/demo-shop/demo-living.html?client=<발급코드>"
echo "  관리자 비밀번호   : grep ADMIN_PASSWORD $WORK_DIR/.env  (계정: admin@widgetrag.com — 이관된 DB 면 소스의 비밀번호)"
echo "  상태 / 로그       : cd $WORK_DIR && sudo docker compose ps · sudo docker compose logs -f backend"
echo "  종료 / 재기동     : cd $WORK_DIR && sudo docker compose down · bash $WORK_DIR/deploy.sh"
echo "  이관 패키지 생성  : cd $WORK_DIR && bash package.sh backup   (UPLOAD_URI=s3://… 면 업로드까지)"
echo "  ※ API 문서(swagger)는 B에서 외부 미노출 — 외부 포트는 frontend 80뿐 (의도된 구성)"
[ "$VERIFY_RESULT" != FAIL ]
