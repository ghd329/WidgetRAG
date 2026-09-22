#!/usr/bin/env bash
# ===========================================================
# [Phase A] 도구 설치 — 최초 1회, 여러 번 실행해도 안전(멱등)
#
#   macOS : Homebrew 기반 (Docker Desktop 대신 Colima — 라이선스 이슈 회피)
#   Ubuntu: 실증(이관 대상 GPU VM) 환경용 최소 절차 — docker/ollama 공식 스크립트
# ===========================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if [ "$OS" = "Darwin" ]; then
  command -v brew >/dev/null 2>&1 || die "Homebrew가 필요합니다 — https://brew.sh"

  log "brew 패키지 설치 (이미 있으면 건너뜀)"
  for pkg in openjdk@17 python@3.12 colima docker docker-compose ollama; do
    brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
  done

  log "설치 확인"
  "$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home/bin/java" -version 2>&1 | head -1
  python3.12 --version
  colima version | head -1
  ollama --version

elif [ "$OS" = "Linux" ]; then
  # Ubuntu 22.04+ 기준. GPU VM에서는 NVIDIA 드라이버가 별도 선행 필요.
  log "apt 패키지 설치"
  sudo apt-get update -y
  sudo apt-get install -y openjdk-17-jdk python3.12 python3.12-venv curl lsof

  if [ "$INFRA_MODE" = "native" ]; then
    # ---- Track A 순수 네이티브: OpenSearch를 호스트에 직접 설치 (Docker 불필요) ----
    # 관계형 DB는 SQLite 임베디드(백엔드 jar에 포함)라 설치할 것이 없다.
    if ! dpkg -s opensearch >/dev/null 2>&1; then
      log "OpenSearch $OS_NATIVE_VERSION 설치 (공식 apt 저장소)"
      curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp | \
        sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/opensearch-keyring
      echo "deb [signed-by=/usr/share/keyrings/opensearch-keyring] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" | \
        sudo tee /etc/apt/sources.list.d/opensearch-2.x.list >/dev/null
      sudo apt-get update -y
      # 2.12+는 설치 시 초기 admin 비밀번호를 요구하나, 아래에서 보안 플러그인을 끄므로 임시값으로 충분
      sudo env OPENSEARCH_INITIAL_ADMIN_PASSWORD='Tmp-Install-2026!' \
        apt-get install -y "opensearch=$OS_NATIVE_VERSION"
    fi

    # 백엔드가 무인증 평문 HTTP로 접속하는 구조 — 보안 플러그인 OFF + 로컬 바인딩 (외부 노출 금지)
    if ! sudo grep -q "widgetrag-local-verification" /etc/opensearch/opensearch.yml 2>/dev/null; then
      sudo tee -a /etc/opensearch/opensearch.yml >/dev/null <<'EOF'

# --- widgetrag-local-verification ---
discovery.type: single-node
plugins.security.disabled: true
network.host: 127.0.0.1
EOF
    fi
    # OpenSearch 필수 커널 파라미터
    echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-opensearch.conf >/dev/null
  else
    command -v docker >/dev/null 2>&1 || {
      log "Docker 설치 (공식 스크립트)"
      curl -fsSL https://get.docker.com | sudo sh
      sudo usermod -aG docker "$USER" && warn "docker 그룹 반영을 위해 재로그인 필요"
    }
  fi

  command -v ollama >/dev/null 2>&1 || {
    log "Ollama 설치 (공식 스크립트)"
    curl -fsSL https://ollama.com/install.sh | sh
  }
else
  die "지원하지 않는 OS: $OS"
fi

log "Phase A 완료 — 다음: ./20-start-infra.sh"
