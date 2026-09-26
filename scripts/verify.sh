#!/usr/bin/env bash
# ===========================================================
# WidgetRAG 합격 기준 자동 검증 — 두 실행 형태 공용 (LexAI verify.sh 와 같은 기준 · 같은 결과 형식)
#
#   bash verify.sh                           # 실행 형태 자동 판별 (RUNTIME=native|compose 로 강제)
#   FORM=gcp-shell RUNS=5 bash verify.sh     # 결과표에 환경 이름 태깅 · 웜 응답 5회로 p50/p95
#   REPEAT=5 bash verify.sh                  # 검증 전체를 5회 연속 — 전 회차 PASS 여야 성공
#
#   Shell 설치형은 scripts/local/50-verify.sh 가 경로·포트를 채워 이 파일을 부른다.
#   Docker Compose 는 deploy.sh 가 이 파일을 배포 디렉토리에 받아 마지막 단계에서 부른다.
#
#   결과는 ~/widgetrag-run/results.csv 에 한 줄씩 누적한다 (LexAI 와 같은 열):
#     timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,result
#     sources = 챗 응답의 추천 상품 수(RAG 근거) · db_msgs = chat_log 건수
#
#   판정 항목
#     1. 구성요소   서비스 · LLM 모델 적재
#     2. 프론트엔드 진입점 HTTP 200 — 브라우저와 같은 경로 (/api 는 프론트의 프록시 경유)
#     3. 인증       관리자 로그인 — 이관된 DB 면 소스의 비밀번호(VERIFY_ADMIN_PASSWORD)
#     4. 채팅       콜드 1회 + 웜 RUNS회 — 추천 상품 > 0 · fallback 아님 · p95 < 180초
#     5. 데이터     색인 문서 수 · SQLite 건수 · 타임존 · FK 정합/강제 · WAL · 동시 쓰기 · 트리거
#     6. 로그 에러  서비스 기동 이후의 에러 흔적 (경고만)
#
#   데이터가 없는 새 환경(가입·업로드 전)은 채팅 검증을 건너뛰고 WARN 으로 둔다.
#   이관 패키지를 복원한 환경은 REQUIRE_DATA=1 — 데이터가 없으면 FAIL.
# ===========================================================
set -uo pipefail
PATH="$PATH:/snap/bin"

if [ -t 1 ]; then
  C_HEAD=$'\033[0;36m'; C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s[%s]%s %s\n' "$C_HEAD" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '%s  PASS%s %s\n' "$C_OK" "$C_OFF" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '%s  FAIL%s %s\n' "$C_ERR" "$C_OFF" "$*"; }

if [ "$(id -u)" -eq 0 ]; then AS_ROOT=""; else AS_ROOT="sudo"; fi

# ---------- 설정 ----------
COMPOSE_DIR="${COMPOSE_DIR:-$HOME/widgetrag-deploy}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$(basename "$COMPOSE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"
STORAGE_DIR="${STORAGE_DIR:-$HOME/widgetrag-data}"
SQLITE_DB_FILE="${SQLITE_DB_FILE:-$STORAGE_DIR/widgetrag.db}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@widgetrag.com}"
QUESTION="${QUESTION:-가장 비싼 상품 추천해줘}"
RUNS="${RUNS:-1}"
REPEAT="${REPEAT:-1}"
REQUIRE_DATA="${REQUIRE_DATA:-0}"
RUN_DIR="${RUN_DIR:-$HOME/widgetrag-run}"
RESULTS="$RUN_DIR/results.csv"
OS="http://127.0.0.1:9200"
UNITS="widgetrag-ai widgetrag-backend widgetrag-frontend"

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
env_value() {  # env_value <키> — compose .env 에서 값 하나 (마지막 값 우선 — compose 와 같은 규칙)
  { $AS_ROOT grep "^$1=" "$COMPOSE_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- ; } || true
}

if [ -z "${RUNTIME:-}" ]; then
  if [ -f "$COMPOSE_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 \
     && [ -n "$(dc ps -q backend 2>/dev/null)" ]; then
    RUNTIME=compose
  else
    RUNTIME=native
  fi
fi

case "$RUNTIME" in
  native)
    FORM="${FORM:-shell-native}"
    FRONT="http://127.0.0.1:${PORT_FRONTEND:-80}"
    DB_SUDO=""
    DB="$SQLITE_DB_FILE"
    APP_TZ="${APP_TZ:-${TZ:-Asia/Seoul}}"
    LOCAL_ADMIN_PASSWORD="${LOCAL_ADMIN_PASSWORD:-}"
    ;;
  compose)
    FORM="${FORM:-docker-compose}"
    FRONT="http://127.0.0.1:80"
    DB_SUDO="$AS_ROOT"          # 볼륨 마운트 지점은 root 만 들어갈 수 있다
    DB="$(docker_cmd volume inspect -f '{{ .Mountpoint }}' "${COMPOSE_PROJECT}_upload-data" 2>/dev/null)/widgetrag.db"
    APP_TZ="${APP_TZ:-$(env_value TZ)}"; APP_TZ="${APP_TZ:-Asia/Seoul}"
    LOCAL_ADMIN_PASSWORD="${LOCAL_ADMIN_PASSWORD:-$(env_value ADMIN_PASSWORD)}"
    OLLAMA_MODEL="${OLLAMA_MODEL:-$(env_value OLLAMA_MODEL)}"
    ;;
  *) die "RUNTIME 은 native 또는 compose 입니다: $RUNTIME" ;;
esac
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:4b}"
mkdir -p "$RUN_DIR"

# ---------- 반복 검증 (REPEAT>1) ----------
# 단발 통과는 우연일 수 있다 — 전체 검증을 N회 돌려 종료코드로 판정하고, 각 회차가
# results.csv 에 한 줄씩 남는다.
if [ "$REPEAT" -gt 1 ] && [ -z "${_VERIFY_CHILD:-}" ]; then
  ok_runs=0
  for i in $(seq 1 "$REPEAT"); do
    if _VERIFY_CHILD=1 REPEAT=1 RUNTIME="$RUNTIME" FORM="$FORM" bash "$0" > "$RUN_DIR/verify-run-$i.log" 2>&1; then
      ok_runs=$((ok_runs + 1)); printf '  run-%02d PASS\n' "$i"
    else
      printf '  run-%02d FAIL  (%s)\n' "$i" "$RUN_DIR/verify-run-$i.log"
    fi
  done
  echo
  log "반복 검증: $ok_runs/$REPEAT PASS — $RESULTS"
  column -s, -t "$RESULTS" 2>/dev/null | tail -"$((REPEAT + 1))"
  [ "$ok_runs" -eq "$REPEAT" ]
  exit $?
fi

# ---------- 접근 경로 ----------
db_query() { ${DB_SUDO} sqlite3 -cmd '.timeout 5000' "$DB" "$1" 2>/dev/null; }
os_curl() {
  if [ "$RUNTIME" = compose ]; then
    dc exec -T opensearch curl -sS "$@" </dev/null   # </dev/null — exec 가 호출자 stdin 을 삼키지 않게
  else
    curl -sS "$@"
  fi
}
now_ms() { date +%s%3N; }
secs()   { awk -v ms="$1" 'BEGIN {printf "%.1f", ms / 1000}'; }
pct() {  # pct <백분위> <값...> — 최근접 순위법 (표본이 적으면 p95 는 사실상 최댓값)
  local p="$1"; shift
  printf '%s\n' "$@" | sort -n | awk -v p="$p" '
    {v[NR] = $1}
    END {
      if (NR == 0) {print 0; exit}
      i = int(p / 100 * NR + 0.9999); if (i < 1) i = 1; if (i > NR) i = NR
      print v[i]
    }'
}
chat() {  # chat <clientCode> <질문> — 응답 본문을 stdout 으로 (프론트의 /api 프록시 경유 · 200 이 아니면 실패)
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"clientCode": sys.argv[1], "question": sys.argv[2]}, ensure_ascii=False))' "$1" "$2")"
  curl -sf --max-time 200 -X POST "$FRONT/api/chat" -H 'Content-Type: application/json' -d "$body"
}
json_field() {  # json_field <python 식> — stdin JSON 에서 값 (실패 시 빈 값)
  python3 -c "import sys,json
try:
    d = json.load(sys.stdin); print($1)
except Exception:
    print('')" 2>/dev/null
}

echo "== WidgetRAG 합격 기준 검증 ($RUNTIME · FORM=$FORM) =="

# ---------- 1. 구성요소 ----------
log "1. 구성요소"
if [ "$RUNTIME" = compose ]; then
  states="$(dc ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)"
  for svc in opensearch llm ai-server backend frontend; do
    line="$(printf '%s\n' "$states" | awk -v s="$svc" '$1 == s')"
    case "$line" in
      *" running unhealthy"*) fail "$svc — unhealthy (docker compose logs $svc)" ;;
      *" running"*)           pass "$svc — ${line#"$svc "}" ;;
      *)                      fail "$svc — 실행 중이 아님 (${line:-없음})" ;;
    esac
  done
  if dc exec -T llm ollama list </dev/null 2>/dev/null | awk '{print $1}' | grep -Fqx "$OLLAMA_MODEL"; then
    pass "모델 $OLLAMA_MODEL 적재"
  else
    fail "모델 $OLLAMA_MODEL 없음 (docker compose logs llm)"
  fi
else
  for unit in opensearch ollama $UNITS; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      pass "$unit — active"
    else
      st="$(systemctl is-active "$unit" 2>/dev/null)"
      fail "$unit — ${st:-확인 불가}"
    fi
  done
  if ollama list 2>/dev/null | awk '{print $1}' | grep -Fqx "$OLLAMA_MODEL"; then
    pass "모델 $OLLAMA_MODEL 적재"
  else
    fail "모델 $OLLAMA_MODEL 없음 (./20-start-infra.sh)"
  fi
fi

# ---------- 2. 프론트엔드 ----------
log "2. 프론트엔드 ($FRONT)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$FRONT/login/company-login.html")"
[ "$code" = 200 ] && pass "HTTP $code" || fail "HTTP ${code:-000} (기대 200)"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$FRONT/widget.js")"
[ "$code" = 200 ] && pass "/widget.js — 프록시 경유 backend 응답" || fail "/widget.js HTTP ${code:-000} — 프론트의 /api 프록시 또는 backend 확인"

# ---------- 3. 인증 ----------
log "3. 인증 (관리자 $ADMIN_EMAIL)"
login() {  # login <비밀번호> — 성공하면 0
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))' "$ADMIN_EMAIL" "$1")"
  curl -s --max-time 15 -X POST "$FRONT/api/members/login" -H 'Content-Type: application/json' -d "$body" \
    | json_field 'd.get("memberId") or ""' | grep -q .
}
if [ -n "${VERIFY_ADMIN_PASSWORD:-}" ]; then
  login "$VERIFY_ADMIN_PASSWORD" && pass "로그인 (VERIFY_ADMIN_PASSWORD — 프록시 경유)" \
                                 || fail "로그인 실패 — VERIFY_ADMIN_PASSWORD 확인 (이관된 DB 면 소스의 비밀번호)"
elif [ -n "$LOCAL_ADMIN_PASSWORD" ]; then
  if login "$LOCAL_ADMIN_PASSWORD"; then
    pass "로그인 (이 환경에서 발급한 비밀번호 — 프록시 경유)"
  else
    # 이관된 DB 에는 소스의 관리자 계정이 있고, 이 환경의 새 비밀번호는 무시된다 — 그 자체가
    # DB 가 옮겨졌다는 신호다. 소스 비밀번호를 알면 VERIFY_ADMIN_PASSWORD 로 판정한다.
    warn "이 환경의 비밀번호로 로그인되지 않음 — 이관된 DB 라면 정상 (VERIFY_ADMIN_PASSWORD=<소스 비밀번호> 로 판정)"
  fi
else
  warn "관리자 비밀번호를 알 수 없어 로그인 검증을 건너뜀 (VERIFY_ADMIN_PASSWORD)"
fi

# ---------- 4. 채팅 ----------
COLD_MS=0; WARM_MS=0; P95_MS=0; SRC_COUNT=0; CHAT_OK=0
CLIENT_CODE="${CLIENT_CODE:-$(db_query "SELECT c.client_code FROM company c JOIN product_item p ON p.company_id = c.id WHERE c.status = 'APPROVED' AND p.deleted_at IS NULL GROUP BY c.id ORDER BY count(*) DESC LIMIT 1;")}"
if [ -z "$CLIENT_CODE" ]; then
  log "4. 채팅"
  if [ "$REQUIRE_DATA" = 1 ]; then
    fail "상품이 있는 승인된 회사가 없습니다 — 이관된 DB 가 비어 있음"
  else
    warn "상품이 있는 승인된 회사가 없어 채팅 검증을 건너뜀 (가입 → 승인 → CSV 업로드 후 다시, 또는 CLIENT_CODE 지정)"
  fi
else
  log "4. 채팅 (clientCode=$CLIENT_CODE · 콜드)"
  t0=$(now_ms)
  resp="$(chat "$CLIENT_CODE" "$QUESTION")"
  COLD_MS=$(( $(now_ms) - t0 ))
  answer_len="$(printf '%s' "$resp" | json_field 'len(d.get("answer") or "")')"
  fallback="$(printf '%s' "$resp" | json_field 'd.get("isFallback")')"
  SRC_COUNT="$(printf '%s' "$resp" | json_field 'len(d.get("recommendedProducts") or [])')"
  SRC_COUNT="${SRC_COUNT:-0}"

  if [ "${answer_len:-0}" -gt 0 ] 2>/dev/null && [ "$fallback" = False ]; then
    pass "답변 생성 ($(secs "$COLD_MS")초, ${answer_len}자)"
    CHAT_OK=1
  elif [ "$fallback" = True ]; then
    fail "fallback 응답 ($(secs "$COLD_MS")초) — 검색 0건 또는 AI 서버 지연·장애"
  else
    fail "답변 없음 ($(secs "$COLD_MS")초) — 응답: ${resp:0:200}"
  fi
  # 추천 상품이 0건이면 색인이 비었거나 벡터 검색이 죽은 것이다. 응답 자체는 200 으로
  # 오기 때문에 이 항목이 없으면 놓친다.
  if [ "$SRC_COUNT" -gt 0 ] 2>/dev/null; then
    pass "추천 상품 ${SRC_COUNT}건 (RAG 동작)"
  else
    fail "추천 상품 0건 — 색인 또는 k-NN 검색 확인"
  fi

  log "4. 채팅 (웜 · ${RUNS}회)"
  # 콜드 응답은 모델의 VRAM 로드가 섞여 기준선으로 쓸 수 없다 — 여기부터가 비교 가능한
  # 수치이고, 이관 전후 동등성의 좌변 · 우변이 된다.
  samples=(); errors=0
  for i in $(seq 1 "$RUNS"); do
    t0=$(now_ms)
    if ! chat "$CLIENT_CODE" "$QUESTION" | json_field 'len(d.get("answer") or "")' | grep -qv '^0*$'; then
      errors=$((errors + 1))
    fi
    ms=$(( $(now_ms) - t0 ))
    samples+=("$ms")
    [ "$RUNS" -gt 1 ] && printf '       %d/%d  %s초\n' "$i" "$RUNS" "$(secs "$ms")"
  done
  WARM_MS="$(pct 50 "${samples[@]}")"
  P95_MS="$(pct 95 "${samples[@]}")"
  # 실패한 호출의 시간은 기준선이 될 수 없다 — 하나라도 실패하면 수치와 무관하게 FAIL.
  # 백엔드의 AI 서버 호출 타임아웃이 180초라 그 아래여야 의미가 있다.
  if [ "$errors" -gt 0 ]; then
    fail "웜 응답 ${errors}/${RUNS}회 실패 — 측정값을 기준선으로 쓸 수 없음"
  elif [ "$P95_MS" -lt 180000 ]; then
    pass "p50 $(secs "$WARM_MS")초 · p95 $(secs "$P95_MS")초 (${RUNS}회)"
  else
    fail "p95 $(secs "$P95_MS")초 — AI 서버 타임아웃(180초) 초과 위험"
  fi
fi

# ---------- 5. 데이터 ----------
log "5. 데이터"
OS_DOCS="$(os_curl "$OS/_cat/indices?h=index,docs.count" 2>/dev/null | awk '$1 !~ /^\./ && NF == 2 {s += $2} END {print s + 0}')"
if [ "${OS_DOCS:-0}" -gt 0 ]; then
  pass "OpenSearch 문서 ${OS_DOCS}건"
elif [ "$REQUIRE_DATA" = 1 ]; then
  fail "OpenSearch 색인이 비어 있음 — 이관 패키지 복원 확인"
else
  warn "OpenSearch 문서 0건 — 데이터 없는 새 환경이면 정상"
fi

if ! ${DB_SUDO} test -s "$DB"; then
  fail "SQLite DB 파일 없음: $DB"
  DB_MSGS=0
else
  DB_MSGS="$(db_query 'SELECT count(*) FROM chat_log;')"
  pass "SQLite company $(db_query 'SELECT count(*) FROM company;') · product_item $(db_query 'SELECT count(*) FROM product_item;') · chat_log ${DB_MSGS:-?}"

  # 타임존: 방금 기록된 chat_log 시각이 지금과 맞는지. created_at 은 타임존 무표기(LocalDateTime)라
  #   - epoch millis(정수): 절대값 → date +%s 와 직접 비교
  #   - TEXT(벽시계): 앱 타임존(APP_TZ) 기준 현재 벽시계와 비교
  # 어긋나면 JVM · 컨테이너 · VM 의 타임존이 갈라진 것 — 이관 데이터와 신규 쓰기의 시각이 뒤엉킨다.
  # 이번 검증에서 새로 쓴 기록으로만 본다 — 채팅이 실패했으면 옛 기록이라 판정 근거가 안 된다
  if [ "$CHAT_OK" = 1 ]; then
    raw="$(db_query 'SELECT MAX(created_at) FROM chat_log;')"
    db_ts=""; ref_ts=""
    case "$raw" in
      "") : ;;
      *[!0-9]*)
        db_ts="$(db_query "SELECT CAST(strftime('%s', '$raw') AS INTEGER);")"
        ref_ts="$(TZ="$APP_TZ" sqlite3 :memory: "SELECT CAST(strftime('%s', datetime('now','localtime')) AS INTEGER);")"
        ;;
      *)
        if [ "${#raw}" -ge 13 ]; then db_ts=$((raw / 1000)); else db_ts="$raw"; fi
        ref_ts="$(date +%s)"
        ;;
    esac
    if [ -n "$db_ts" ] && [ -n "$ref_ts" ]; then
      drift=$(( ref_ts - db_ts )); [ "$drift" -lt 0 ] && drift=$(( -drift ))
      if [ "$drift" -lt 3600 ]; then
        pass "타임존 — 마지막 기록 $raw (APP_TZ=$APP_TZ, 차이 ${drift}초)"
      else
        fail "타임존 — 마지막 기록 $raw 이 현재와 ${drift}초 어긋남 (APP_TZ=$APP_TZ · JVM/컨테이너 TZ 확인)"
      fi
    fi
  fi

  # 참조 무결성: SQLite 는 FK 가 커넥션마다 기본 OFF 라 설정이 빠지면 선언만 되고 검사되지 않는다.
  # 1) 실제 데이터에 고아 행이 있는가  2) 설정이 실제로 들어 있는가 — 1) 은 데이터가 적으면 통과할 수 있다
  orphans="$( { db_query 'PRAGMA foreign_keys=ON; PRAGMA foreign_key_check;' | grep -c . ; } || true )"
  if [ "$RUNTIME" = native ]; then
    fk_cfg="$( { grep -c 'foreign_keys=true' "${FK_CONFIG_FILE:-/dev/null}" 2>/dev/null; } || true )"
  else
    # compose 는 JDBC URL 이 이미지 안(application-docker.yaml)에 있다 — v0.3.0 부터 반영
    case "${IMAGE_TAG:-$(env_value IMAGE_TAG)}" in v0.1.*|v0.2.*) fk_cfg=0 ;; *) fk_cfg=1 ;; esac
  fi
  if [ "${orphans:-0}" -eq 0 ] && [ "${fk_cfg:-0}" -ge 1 ]; then
    pass "참조 무결성 (고아 행 0 · FK 강제 설정됨)"
  elif [ "${orphans:-0}" -gt 0 ]; then
    fail "고아 행 ${orphans}건 — FK 가 강제되지 않은 채 기록됐습니다"
  else
    fail "FK 강제 설정(foreign_keys=true)이 없습니다 — native: application-local.yaml · compose: 이미지 v0.3.0+"
  fi

  [ "$(db_query 'PRAGMA journal_mode;')" = wal ] && pass "WAL 모드" || fail "journal_mode 가 wal 이 아님"

  # 동시 쓰기: 두 프로세스가 동시에 써도 database is locked 없이 전부 반영돼야 한다
  # (WAL + busy_timeout — 스크래치 테이블을 쓰고 지운다, 서비스 데이터 무관)
  if db_query "CREATE TABLE IF NOT EXISTS _verify_scratch(k TEXT); DELETE FROM _verify_scratch;" >/dev/null; then
    for w in 1 2; do
      ( for i in $(seq 1 25); do db_query "INSERT INTO _verify_scratch VALUES('w$w-$i');" >/dev/null || exit 1; done ) &
      eval "W${w}_PID=$!"
    done
    wait "$W1_PID"; w1=$?
    wait "$W2_PID"; w2=$?
    rows="$(db_query 'SELECT count(*) FROM _verify_scratch;')"
    db_query 'DROP TABLE IF EXISTS _verify_scratch;' >/dev/null
    if [ "$w1" -eq 0 ] && [ "$w2" -eq 0 ] && [ "$rows" = 50 ]; then
      pass "동시 쓰기 (2 writer × 25행, busy_timeout)"
    else
      fail "동시 쓰기 — ${rows:-0}/50행 반영 (database is locked?)"
    fi
  else
    fail "동시 쓰기 — 스크래치 테이블 생성 실패 (DB 잠김?)"
  fi

  triggers="$(db_query "SELECT count(*) FROM sqlite_master WHERE type='trigger';")"
  if [ -n "${EXPECT_TRIGGERS:-}" ]; then
    [ "$triggers" = "$EXPECT_TRIGGERS" ] && pass "트리거 수 일치 ($triggers)" || fail "트리거 수 불일치 (소스 $EXPECT_TRIGGERS / 여기 $triggers)"
  else
    printf '  INFO 트리거 %s개 (소스와 대조하려면 EXPECT_TRIGGERS=<소스 값>)\n' "$triggers"
  fi
fi

# ---------- 6. 로그 에러 ----------
log "6. 로그 에러"
# 서비스가 켜진 시점 이후만 본다 — 이전 회차의 실패가 이번 판정에 섞이면 안 된다.
PATTERN='Traceback \(most recent|^Caused by:|Exception in thread| ERROR '
errs=0
if [ "$RUNTIME" = compose ]; then
  for svc in backend ai-server; do
    cid="$(dc ps -q "$svc" 2>/dev/null)"
    [ -n "$cid" ] || continue
    since="$(docker_cmd inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null)"
    n="$( { dc logs --no-color ${since:+--since "$since"} "$svc" 2>/dev/null | grep -cE "$PATTERN"; } || true )"
    if [ "${n:-0}" -gt 0 ]; then warn "$svc 에 에러 흔적 ${n}건 — docker compose logs $svc"; errs=$((errs + n)); fi
  done
else
  for unit in $UNITS; do
    systemctl is-active --quiet "$unit" 2>/dev/null || continue
    since="$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)"
    n="$( { journalctl -u "$unit" ${since:+--since "$since"} --no-pager 2>/dev/null | grep -cE "$PATTERN"; } || true )"
    if [ "${n:-0}" -gt 0 ]; then warn "$unit 에 에러 흔적 ${n}건 — journalctl -u $unit"; errs=$((errs + n)); fi
  done
fi
[ "$errs" -eq 0 ] && pass "에러 없음" || warn "총 ${errs}건 — 치명적인지는 직접 확인하세요"

# ---------- 결과 누적 ----------
HEADER="timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,result"
# 열이 바뀐 뒤 옛 파일에 덧붙이면 칸이 밀려 읽을 수 없다 — 헤더가 다르면 비켜두고 새로 시작한다.
if [ -f "$RESULTS" ] && [ "$(head -1 "$RESULTS")" != "$HEADER" ]; then
  mv "$RESULTS" "${RESULTS%.csv}-$(date +%Y%m%d-%H%M%S).csv"
  warn "결과 형식이 바뀌어 이전 기록을 따로 보관했습니다"
fi
[ -f "$RESULTS" ] || echo "$HEADER" > "$RESULTS"
VERDICT="$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
echo "$(date '+%Y-%m-%d %H:%M:%S'),${FORM},${RUNS},${PASS},${FAIL},$(secs "$COLD_MS"),$(secs "$WARM_MS"),$(secs "$P95_MS"),${SRC_COUNT:-0},${OS_DOCS:-0},${DB_MSGS:-0},${VERDICT}" >> "$RESULTS"

echo
log "결과: ${PASS} PASS / ${FAIL} FAIL → ${VERDICT}"
echo "  누적 기록: $RESULTS"
column -s, -t "$RESULTS" 2>/dev/null | tail -5
[ "$FAIL" -eq 0 ]
