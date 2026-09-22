#!/usr/bin/env bash
# ===========================================================
# [Docker Compose(B)] 셋업 + 기동 — bootstrap.sh --compose 가 호출하는 B 트랙 진입점
#
#   NVIDIA 드라이버는 bootstrap.sh가 이미 처리한 상태를 전제한다.
#   수행 내용 (멱등):
#     1) Docker 엔진 설치 (없으면 — 공식 스크립트)
#     2) nvidia-container-toolkit 설치·구성 (GPU 있으면 — compose의 GPU 예약에 필수)
#     3) .env 생성 (없으면 — ADMIN_PASSWORD 무작위, DOMAIN=:80, CORS는 터널 포트 8081)
#     4) 기동: 기본은 소스 빌드(build → up).
#        레지스트리 pull 방식(이관 실증 원형)은 COMPOSE_SOURCE=pull DOCKERHUB_USER=<계정> 지정
#
#   ※ docker 그룹 반영은 재로그인이 필요하므로, 이 스크립트 안에서는 sudo docker를 사용한다.
#     재로그인 후에는 sudo 없이 docker compose 사용 가능.
# ===========================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_SOURCE="${COMPOSE_SOURCE:-build}"   # build | pull

log() { printf '\033[1;32m[compose-setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[compose-setup][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. Docker 엔진 ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker 설치 (공식 스크립트)"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  log "docker 그룹 등록 — 재로그인 후 sudo 없이 사용 가능 (지금은 sudo로 계속 진행)"
fi
sudo docker info >/dev/null 2>&1 || die "Docker 데몬에 연결 불가"

# ---------- 2. nvidia-container-toolkit (GPU 있으면) ----------
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
  log "GPU 미감지 — toolkit 생략 (compose의 GPU 예약 서비스는 기동 실패할 수 있음)"
fi

# ---------- 3. .env ----------
cd "$PROJECT_ROOT"
if [ -f .env ]; then
  log ".env 이미 존재 — 유지"
else
  log ".env 생성 (.env.example 기반 — 무인 검증 기본값)"
  cp .env.example .env
  sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)/" .env
  sed -i 's/^DOMAIN=.*/DOMAIN=:80/' .env                                          # 터널 접속용 평문 80 서빙
  sed -i 's#^CORS_ALLOWED_ORIGINS=.*#CORS_ALLOWED_ORIGINS=http://localhost:8081#' .env
  log "관리자 비밀번호는 .env에서 확인: grep ADMIN_PASSWORD .env"
fi

# ---------- 4. 기동 ----------
if [ "$COMPOSE_SOURCE" = "pull" ]; then
  [ -n "${DOCKERHUB_USER:-}" ] || grep -q '^DOCKERHUB_USER=' .env || die "pull 방식은 DOCKERHUB_USER 필요 (env 또는 .env)"
  [ -n "${DOCKERHUB_USER:-}" ] && { grep -q '^DOCKERHUB_USER=' .env || echo "DOCKERHUB_USER=$DOCKERHUB_USER" >> .env; }
  log "레지스트리 pull 기동 (이관 실증 원형 — docker-compose.images.yml)"
  sudo docker compose -f docker-compose.yml -f docker-compose.images.yml pull
  sudo docker compose -f docker-compose.yml -f docker-compose.images.yml up -d --no-build
else
  log "소스 빌드 기동 (build → up) — 최초 빌드 수 분 소요"
  sudo docker compose build
  sudo docker compose up -d
fi

log "컨테이너 상태:"
sudo docker compose ps
log "완료 — E2E 확인은 [Mac] 터널: ssh -N -L 8081:localhost:80 ubuntu@<IP> 후 http://localhost:8081"
