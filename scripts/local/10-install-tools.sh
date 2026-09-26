#!/usr/bin/env bash
# ===========================================================
# [Phase A] 도구 설치 — 최초 1회, 여러 번 실행해도 안전(멱등)
#
#   실증(이관 대상 GPU VM) 환경용 — Ubuntu 22.04+ 기준.
#   전 구성요소 네이티브 설치 (Track A — Docker 없음).
#   GPU VM에서는 NVIDIA 드라이버가 별도 선행 필요 (bootstrap.sh가 자동화).
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

log "apt 패키지 설치"
sudo apt-get update -y
# nginx — 프론트(정적 화면 + /api 프록시, Docker Compose 형태와 같은 nginx.conf)
# pigz  — 이관 패키지 압축을 코어 수만큼 병렬로 (scripts/package.sh)
apt_install openjdk-17-jdk python3.12 python3.12-venv curl lsof sqlite3 nginx pigz

# 배포판 nginx 서비스는 끈다 — 80 포트는 widgetrag-frontend 유닛(40-start-apps.sh)이 쓴다
sudo systemctl disable --now nginx >/dev/null 2>&1 || true

# ---- OpenSearch: 호스트에 직접 설치 (관계형 DB는 SQLite 임베디드 — 설치할 것이 없다) ----
if ! dpkg -s opensearch >/dev/null 2>&1; then
  log "OpenSearch $OPENSEARCH_VERSION 설치 (공식 apt 저장소)"
  curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp | \
    sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/opensearch-keyring
  echo "deb [signed-by=/usr/share/keyrings/opensearch-keyring] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" | \
    sudo tee /etc/apt/sources.list.d/opensearch-2.x.list >/dev/null
  sudo apt-get update -y
  # 2.12+는 설치 시 초기 admin 비밀번호를 요구하나, 아래에서 보안 플러그인을 끄므로 임시값으로 충분
  sudo env DEBIAN_FRONTEND=noninteractive OPENSEARCH_INITIAL_ADMIN_PASSWORD='Tmp-Install-2026!' \
    apt-get install -y -q "opensearch=$OPENSEARCH_VERSION"
fi

# 백엔드가 무인증 평문 HTTP로 접속하는 구조 — 보안 플러그인 OFF + 로컬 바인딩 (외부 노출 금지)
if ! sudo grep -q "widgetrag-local-verification" /etc/opensearch/opensearch.yml 2>/dev/null; then
  sudo tee -a /etc/opensearch/opensearch.yml >/dev/null <<'EOF'

# --- widgetrag-local-verification ---
discovery.type: single-node
plugins.security.disabled: true
network.host: 127.0.0.1
path.repo: ["/var/lib/opensearch/snapshots"]
EOF
fi
# 스냅샷 저장소 경로 — 이관 패키지의 색인을 여기로 넣고 뺀다 (scripts/package.sh).
# 위 블록보다 먼저 설치된 VM 은 package.sh 가 처음 쓸 때 path.repo 를 한 번 추가·재시작한다.
sudo install -d -o opensearch -g opensearch /var/lib/opensearch/snapshots
# OpenSearch 필수 커널 파라미터
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-opensearch.conf >/dev/null

command -v ollama >/dev/null 2>&1 || {
  log "Ollama 설치 (공식 스크립트)"
  curl -fsSL https://ollama.com/install.sh | sh
}

log "Phase A 완료 — 다음: ./20-start-infra.sh"
