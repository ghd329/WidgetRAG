#!/usr/bin/env bash
# ===========================================================
# WidgetRAG shell 설치형 기동 스크립트 — 공통 설정/함수
#
# 모든 스크립트가 이 파일을 source 한다. 직접 실행하는 파일이 아님.
# 값을 바꾸려면 실행 전에 동명의 환경변수를 export 하면 된다.
#   예) WIDGETRAG_ADMIN_PASSWORD='...' ./40-start-apps.sh
# ===========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 실증 산출물 — Ubuntu Linux GPU VM 전용 (Track A: 전 구성요소 네이티브, Docker 없음).
# macOS 등 로컬 우회 경로는 두지 않는다 — 로컬 검증이 필요하면 Docker Compose(B) 트랙을 사용.
if [ "$(uname -s)" != "Linux" ]; then
  printf '\033[1;31m[widgetrag][FAIL]\033[0m 이 스크립트는 실증 환경(Ubuntu Linux) 전용입니다 — 로컬 검증은 Docker Compose 트랙을 사용하세요\n' >&2
  exit 1
fi

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춘다.
# (sudo 는 환경변수를 넘기지 않으므로 apt 호출은 apt_install 로 — sudo env 로 명시 전달)
export DEBIAN_FRONTEND=noninteractive

# --- 포트 ---
# 프론트는 nginx 로 띄워 /api 를 백엔드로 프록시한다 (Docker Compose 형태와 같은 frontend/nginx.conf).
# 화면과 API 가 같은 오리진이 되어, 두 형태 모두 SSH 터널 하나(-L 8081:localhost:80)로 접속한다.
# ※ 5500/5501/3000 은 쓰지 말 것 — api.js 가 이 포트를 "로컬 개발"로 보고 :8080 을 직접 부른다.
PORT_FRONTEND="${PORT_FRONTEND:-80}"
PORT_BACKEND="${PORT_BACKEND:-8080}"
PORT_AI="${PORT_AI:-8000}"
PORT_OLLAMA="${PORT_OLLAMA:-11434}"
PORT_OPENSEARCH="${PORT_OPENSEARCH:-9200}"

# --- OpenSearch (apt 설치, 버전 고정 — 이관 시 소스·타겟 버전 일치 필수) ---
#   ※ 관계형 DB는 SQLite 임베디드(백엔드 프로세스 내장)라 인프라 기동 대상이 아님
OPENSEARCH_VERSION="2.18.0"

# --- LLM 모델 ---
# 기본 Gemma 3 4B (약 3.3GB) — Gemma 이용약관은 산출물 오픈소스 리스트(OLA)에 표기.
# EXAONE은 연구용 라이선스 제약이 있어 기본값에서 제외 (필요 시 OLLAMA_MODEL로 지정).
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:4b}"
# 사내망에서 Ollama 레지스트리 대용량 블롭이 차단될 때의 우회 경로 (HuggingFace GGUF)
OLLAMA_MODEL_HF_FALLBACK="${OLLAMA_MODEL_HF_FALLBACK:-hf.co/unsloth/gemma-3-4b-it-GGUF:Q4_K_M}"

# --- 관리자 계정 (백엔드 최초 기동 시 생성) ---
WIDGETRAG_ADMIN_EMAIL="${WIDGETRAG_ADMIN_EMAIL:-admin@widgetrag.com}"
# 비밀번호 기본값을 저장소에 두지 않는다 (실증 환경은 "운영에 준하는" 구성이 요구됨).
# 미지정 시 최초 실행에서 무작위 생성해 .admin-password(600)에 저장, 이후 실행은 재사용(멱등).
ADMIN_PW_FILE="$SCRIPT_DIR/.admin-password"
if [ -z "${WIDGETRAG_ADMIN_PASSWORD:-}" ]; then
  if [ -f "$ADMIN_PW_FILE" ]; then
    WIDGETRAG_ADMIN_PASSWORD="$(cat "$ADMIN_PW_FILE")"
  else
    # (die는 아래 공통 함수 절에서 정의되므로 여기서는 인라인 처리)
    command -v openssl >/dev/null 2>&1 || { printf '[widgetrag][FAIL] openssl 필요 (관리자 비밀번호 자동 생성) — 또는 WIDGETRAG_ADMIN_PASSWORD 지정\n' >&2; exit 1; }
    WIDGETRAG_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    ( umask 177 && printf '%s' "$WIDGETRAG_ADMIN_PASSWORD" > "$ADMIN_PW_FILE" )
  fi
fi

# --- 콘솔 접속 오리진 · 위젯 공개 주소 (Docker Compose 형태의 .env 기본값과 같게) ---
# 브라우저는 SSH 터널(localhost:8081)로 들어오므로 그 오리진을 CORS 에 등록한다.
CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:8081,http://127.0.0.1:8081}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://localhost:8081}"

# --- 타임존 ---
# 엔티티 시각(LocalDateTime.now)은 JVM 기본 타임존 = 프로세스의 TZ 를 따른다. VM 이미지마다
# 기본값이 달라(UTC/KST) 명시하지 않으면 이관 전후로 기록 시각이 9시간 갈린다 (LexAI 와 같은 기준).
APP_TZ="${APP_TZ:-Asia/Seoul}"

# --- LLM 생성 파라미터 ---
# 동등성 검증(이관 전후 추론 결과 일치 비교)은 결정적 설정이 필요:
#   LLM_TEMPERATURE=0 LLM_SEED=42 ./40-start-apps.sh
LLM_TEMPERATURE="${LLM_TEMPERATURE:-0.7}"
LLM_SEED="${LLM_SEED:-}"          # 비우면 미지정(비결정적)

# --- systemd (Linux 앱 계층) ---
# Linux에서는 앱 3종을 systemd 유닛으로 기동한다 — 마이그레이션 도구가 식별할
# "실행 파일·환경변수"가 표준 위치(유닛 파일·EnvironmentFile)에 드러나게 하기 위함.
WIDGETRAG_ENV_FILE="/etc/widgetrag/widgetrag.env"
SYSTEMD_UNITS=(widgetrag-ai widgetrag-backend widgetrag-frontend)

# --- 경로 ---
STORAGE_DIR="${STORAGE_DIR:-$HOME/widgetrag-data}"   # CSV 업로드 파일 저장 경로
SQLITE_DB_FILE="${SQLITE_DB_FILE:-$STORAGE_DIR/widgetrag.db}"   # SQLite DB 파일 (업로드 경로와 같은 곳에 두어 함께 이관)
PACKAGE_DIR="${PACKAGE_DIR:-$HOME/widgetrag-package}"           # 받은 이관 패키지 (SNAPSHOT_URI → 35-restore-package.sh)
PACKAGE_SH="$PROJECT_ROOT/scripts/package.sh"                    # 이관 패키지 도구 (두 형태 공용)
FRONTEND_NGINX_CONF="/etc/widgetrag/frontend-nginx.conf"         # frontend/nginx.conf 에서 생성 (40-start-apps.sh)
LOG_DIR="$SCRIPT_DIR/logs"
PID_DIR="$SCRIPT_DIR/pids"
AI_DIR="$PROJECT_ROOT/ai-server"
BACKEND_DIR="$PROJECT_ROOT/backend"
FRONTEND_DIR="$PROJECT_ROOT/frontend"
VENV_DIR="$AI_DIR/.venv"

# --- Python (AI 서버 venv 생성용 — 3.12 필수, 3.14는 torch 미지원) ---
PYTHON_BIN="${PYTHON_BIN:-python3.12}"

mkdir -p "$LOG_DIR" "$PID_DIR"

# ---------- 공통 함수 ----------
# 이관 도구로 실행되면 TTY 가 없고 출력이 로그로 수집된다 — 그때는 색상 제어문자를 쓰지 않는다.
if [ -t 1 ]; then
  log()  { printf '\033[1;32m[widgetrag]\033[0m %s\n' "$*"; }
  warn() { printf '\033[1;33m[widgetrag][WARN]\033[0m %s\n' "$*"; }
  die()  { printf '\033[1;31m[widgetrag][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
else
  log()  { printf '[widgetrag] %s\n' "$*"; }
  warn() { printf '[widgetrag][WARN] %s\n' "$*"; }
  die()  { printf '[widgetrag][FAIL] %s\n' "$*" >&2; exit 1; }
fi

apt_install() {  # apt_install <패키지...> — 비대화형 (sudo 가 DEBIAN_FRONTEND 를 지우므로 env 로 넘긴다)
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q "$@"
}

port_listening() {  # $1=port
  # ss는 타 유저 소유 소켓도 보임 (lsof는 일반 유저 권한으로 opensearch/ollama 등
  # 시스템 서비스의 소켓을 못 봐서 "미기동" 오탐 — 2026-09-21 EC2에서 실제 발생)
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

wait_for_http() {  # $1=url $2=이름 $3=타임아웃(초)
  local url="$1" name="$2" timeout="${3:-60}" waited=0
  printf '[widgetrag] %s 대기 중' "$name"
  until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
    waited=$((waited + 3))
    if [ "$waited" -ge "$timeout" ]; then
      printf '\n'; die "$name 응답 없음 — $url (${timeout}s 초과). 로그: $LOG_DIR"
    fi
    printf '.'; sleep 3
  done
  printf ' OK\n'
}

resolve_java() {  # JAVA_HOME 확보 (PATH의 java 실경로 역산)
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then return 0; fi
  if command -v java >/dev/null 2>&1; then
    # /usr/bin/java(심링크) → 실제 JDK 경로로 역산해 JAVA_HOME 설정
    # (설정 없이 두면 기동 명령의 "$JAVA_HOME/bin/java"가 unbound variable — 2026-09-21 EC2에서 실제 발생)
    local jbin jhome
    jbin="$(readlink -f "$(command -v java)")" || die "java 실경로 확인 실패 (readlink)"
    jhome="$(dirname "$(dirname "$jbin")")"
    export JAVA_HOME="$jhome"
    return 0
  fi
  die "Java 17을 찾을 수 없음 — 10-install-tools.sh 먼저 실행"
}

save_pid()  { echo "$2" > "$PID_DIR/$1.pid"; }
kill_pidfile() {  # $1=이름
  local f="$PID_DIR/$1.pid"
  if [ -f "$f" ]; then
    local pid; pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" && log "$1 종료 (pid $pid)"; fi
    rm -f "$f"
  fi
}
