#!/usr/bin/env bash
# ===========================================================
# WidgetRAG — Docker Compose(B) 타겟 배포 스크립트
#
#   저장소에 있지만 타겟은 clone하지 않는다 — 이 파일 하나만 raw로 받아 실행하면
#   compose 정의를 수신해 pull → up 으로 서비스가 뜬다 (타겟에 소스·git 불필요).
#
#   사용법 (신규 Ubuntu GPU VM):
#     curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/compose/deploy.sh -o deploy.sh
#     bash deploy.sh
#
#   ⚠️ `curl … | bash` 파이프 실행 금지 — 스크립트 내부 명령이 stdin을 소비하면
#     남은 본문이 잘린 채 종료코드 0으로 조용히 끝날 수 있다 (LexAI 검증 결함4 실측).
#     반드시 디스크 사본으로 실행하며, 아래 가드가 파이프 실행을 차단한다.
#
#   수행 내용 (멱등 — 재실행하면 이어서 진행):
#     1) NVIDIA 드라이버 (GPU 있고 미설치면 설치 → 재부팅 안내 → 재실행으로 이어감)
#     2) Docker 엔진 + nvidia-container-toolkit (+컨테이너 GPU 통과 확인)
#     3) 배포 파일 3개 수신 (docker-compose.yml / docker-compose.images.yml / Caddyfile — 이게 저장소에서 받는 전부)
#     4) .env 생성 (없으면 — 관리자 비밀번호 무작위 발급)
#     5) docker compose pull → up -d --no-build (레지스트리 이미지 기동 — 빌드 경로 없음)
#
#   환경변수 (기본값으로 무인 실행 가능):
#     REGISTRY_PREFIX 이미지 레지스트리 주소/계정 (기본 yjp8842 = Docker Hub)
#                     ECR: <계정ID>.dkr.ecr.<리전>.amazonaws.com · GAR: <리전>-docker.pkg.dev/<프로젝트>/<저장소>
#                     NCR: <레지스트리>.kr.ncr.ntruss.com — 프라이빗 레지스트리는 docker login 선행
#     IMAGE_TAG       이미지 태그 (기본 v0.3.0 — FK 강제까지 반영, 고정 태그만·latest 금지)
#     BRANCH          배포 파일을 받아올 브랜치/태그 (기본 feat/20260922-change-sqlite)
#     WORK_DIR        배포 디렉토리 (기본 ~/widgetrag-deploy)
#     NO_DRIVER=1     드라이버 단계 건너뜀 (GPU 없는 검증 VM)
#
#   기동 후: 모델(gemma3:4b, 약 3.3GB)은 llm 컨테이너가 자동 pull — 최초 수 분 소요.
# ===========================================================
set -euo pipefail

# 파이프 실행 차단 — curl | bash 로 오면 BASH_SOURCE가 실파일이 아니다
if [ ! -f "${BASH_SOURCE[0]:-}" ]; then
  printf '\033[1;31m[compose-deploy][FAIL]\033[0m 파이프 실행 금지 — 파일로 받아 실행하세요: curl -fsSL <raw URL> -o deploy.sh && bash deploy.sh\n' >&2
  exit 1
fi

# 명시 지정 여부를 기본값 적용 전에 기억 — 재실행 시 기존 .env에 그 값만 갱신하기 위함
REGISTRY_PREFIX_ARG="${REGISTRY_PREFIX:-}"
IMAGE_TAG_ARG="${IMAGE_TAG:-}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-yjp8842}"
IMAGE_TAG="${IMAGE_TAG:-v0.3.0}"
BRANCH="${BRANCH:-feat/20260922-change-sqlite}"
WORK_DIR="${WORK_DIR:-$HOME/widgetrag-deploy}"
RAW_BASE="https://raw.githubusercontent.com/ghd329/WidgetRAG/$BRANCH"

log() { printf '\033[1;32m[compose-deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[compose-deploy][WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[compose-deploy][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "타겟 VM(Ubuntu Linux) 전용 스크립트입니다"

# ---------- 1. NVIDIA 드라이버 (GPU 있고 미설치면) ----------
if [ "${NO_DRIVER:-}" != "1" ] && ! nvidia-smi >/dev/null 2>&1; then
  command -v lspci >/dev/null 2>&1 || sudo apt-get install -y pciutils >/dev/null 2>&1 || true
  if lspci 2>/dev/null | grep -qi nvidia; then
    log "NVIDIA GPU 감지, 드라이버 미동작 — 드라이버 설치"
    sudo apt-get update -y && sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers install
    warn "드라이버 반영에 재부팅 필요: sudo reboot 후 이 스크립트를 다시 실행하세요 (이어서 진행됨)"
    exit 0
  fi
fi
nvidia-smi >/dev/null 2>&1 && log "GPU 확인: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

# ---------- 2. Docker 엔진 ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker 설치 (공식 스크립트)"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  log "docker 그룹 등록 — 재로그인 후 sudo 없이 사용 가능 (지금은 sudo로 계속 진행)"
fi
sudo docker info >/dev/null 2>&1 || die "Docker 데몬에 연결 불가"

# ---------- 3. nvidia-container-toolkit (GPU 있으면) ----------
if nvidia-smi >/dev/null 2>&1 && ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "nvidia-container-toolkit 설치 (compose의 GPU 예약에 필수)"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  log "컨테이너 GPU 통과 확인"
  sudo docker run --rm --gpus all ubuntu nvidia-smi >/dev/null || die "컨테이너에서 GPU 미인식 — toolkit 구성 확인"
elif ! nvidia-smi >/dev/null 2>&1; then
  warn "GPU 미감지 — toolkit 생략 (GPU 예약 서비스는 기동 실패할 수 있음, EMBEDDING_DEVICE=cpu로 진행)"
fi

# ---------- 4. 배포 파일 수신 (저장소에서 받는 전부 — git·소스 없음) ----------
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
log "배포 파일 수신: $RAW_BASE ($BRANCH)"
curl -fsSL "$RAW_BASE/docker-compose.yml"        -o docker-compose.yml        || die "docker-compose.yml 수신 실패"
curl -fsSL "$RAW_BASE/docker-compose.images.yml" -o docker-compose.images.yml || die "docker-compose.images.yml 수신 실패"
# caddy가 바인드 마운트하는 Caddyfile — 호스트에 없으면 도커가 디렉토리로 자동 생성해 기동이 깨진다
[ -d Caddyfile ] && sudo rm -rf Caddyfile   # 과거 실패가 남긴 디렉토리 잔재 정리
curl -fsSL "$RAW_BASE/Caddyfile" -o Caddyfile || die "Caddyfile 수신 실패"

# ---------- 5. .env 생성 (없으면 — 무인 검증 기본값) ----------
if [ -f .env ]; then
  # 기존 .env 유지 — 단, 이번 실행에서 명시 지정한 값은 갱신한다
  # (안 그러면 IMAGE_TAG=v0.4.0 지정이 기존 .env의 옛 값에 조용히 밀리는 함정)
  for kv in "REGISTRY_PREFIX=$REGISTRY_PREFIX_ARG" "IMAGE_TAG=$IMAGE_TAG_ARG"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ -n "$v" ] || continue
    if grep -q "^$k=" .env; then sed -i "s|^$k=.*|$k=$v|" .env; else echo "$k=$v" >> .env; fi
    log ".env 갱신: $k=$v (명시 지정)"
  done
  log ".env 유지 — 적용값: $(grep -E '^(REGISTRY_PREFIX|IMAGE_TAG)=' .env | tr '\n' ' ')"
else
  command -v openssl >/dev/null 2>&1 || sudo apt-get install -y openssl >/dev/null 2>&1
  EMBED_DEV="$(nvidia-smi >/dev/null 2>&1 && echo cuda || echo cpu)"
  log ".env 생성 (관리자 비밀번호 무작위 발급, EMBEDDING_DEVICE=$EMBED_DEV)"
  cat > .env <<EOF
# scripts/compose/deploy.sh 가 생성 — 무인 검증 기본값
ADMIN_EMAIL=admin@widgetrag.com
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
DOMAIN=:80
PUBLIC_BASE_URL=http://localhost
CORS_ALLOWED_ORIGINS=http://localhost:8081
SESSION_SECURE=false
SESSION_SAME_SITE=lax
EMBEDDING_DEVICE=$EMBED_DEV
OLLAMA_MODEL=gemma3:4b
REGISTRY_PREFIX=$REGISTRY_PREFIX
IMAGE_TAG=$IMAGE_TAG
EOF
  chmod 600 .env
  log "관리자 비밀번호는 .env에서 확인: grep ADMIN_PASSWORD $WORK_DIR/.env"
fi

# ---------- 6. 레지스트리 이미지 기동 (빌드 없음) ----------
# compose는 .env를 읽으므로 실제 적용값도 .env에서 가져와 출력 (스크립트 변수와 어긋나지 않게)
EFF_PREFIX="$(grep '^REGISTRY_PREFIX=' .env | cut -d= -f2)"
EFF_TAG="$(grep '^IMAGE_TAG=' .env | cut -d= -f2)"
log "이미지 pull: ${EFF_PREFIX}/widgetrag:*-${EFF_TAG}"
sudo docker compose -f docker-compose.yml -f docker-compose.images.yml pull
log "기동 (up -d --no-build)"
sudo docker compose -f docker-compose.yml -f docker-compose.images.yml up -d --no-build

# ---------- 7. 확인 ----------
log "진입점(caddy :80) 응답 대기 — 최초 기동은 모델 pull(3.3GB)로 수 분 걸릴 수 있음"
WAITED=0
until curl -fsS -o /dev/null --max-time 5 "http://localhost:80/" 2>/dev/null; do
  WAITED=$((WAITED + 10))
  [ "$WAITED" -ge 600 ] && { warn "600s 내 응답 없음 — 아래 상태/로그로 확인"; break; }
  printf '.'; sleep 10
done
echo
sudo docker compose ps
echo
log "완료 — 타겟에 있는 것: 이 스크립트 + compose 2개 + Caddyfile + .env + 컨테이너 (소스·git 없음)"
echo "  [로컬 PC] 터널    : ssh -N -L 8081:localhost:80 ubuntu@<타겟IP>   (이후 로컬 브라우저로 접속)"
echo "  콘솔(가입/로그인) : http://localhost:8081/login/company-signup.html"
echo "  데모샵(위젯)      : http://localhost:8081/demo-shop/demo-living.html?client=<발급코드>"
echo "  관리자 비밀번호   : grep ADMIN_PASSWORD $WORK_DIR/.env  (계정: admin@widgetrag.com)"
echo "  상태 / 로그       : cd $WORK_DIR && sudo docker compose ps · sudo docker compose logs -f backend"
echo "  종료 / 재기동     : cd $WORK_DIR && sudo docker compose down · 이 스크립트 재실행"
echo "  ※ API 문서(swagger)는 B에서 외부 미노출 — 외부 포트는 caddy 80뿐 (의도된 구성)"
