#!/usr/bin/env bash
# ===========================================================
# 기동 상태 점검 — 6개 구성요소 헬스 체크 + SQLite 기능 등가성 (+ 선택: 챗봇 스모크 테스트)
#
#   사용법:
#     ./50-verify.sh                          # 서비스 헬스 + SQLite 등가성
#     CLIENT_CODE=shop_xxxx ./50-verify.sh    # RAG 챗봇 E2E 스모크 테스트까지 (+ 타임존 검증)
#     RUNS=5 CLIENT_CODE=... ./50-verify.sh   # 반복 검증 — N회 연속 자동판정 + verify-history.tsv 누적
#     FORM=aws-shell RUNS=5 ... ./50-verify.sh  # 결과표에 환경 이름 태깅 (CSP 간·형태 간 비교용)
#                                               # 미지정 시 shell-$INFRA_MODE (예: shell-native)
#
#   LexAI 병행 검증(2026-09-22)에서 이식한 장치:
#     - 반복 검증: 단발 통과는 우연일 수 있다 — 종료코드 기반 자동판정을 N회 누적,
#       전 회차 PASS여야 성공. 회차별 챗 응답 시간도 기록해 워밍업 추세(콜드→웜)가 남는다.
#     - SQLite 기능 등가성: 파일이 옮겨졌는가(정합성)와 별개로, 전환된 임베디드 DB가
#       원본 RDB(PostgreSQL)와 등가로 동작하는가 — FK·WAL 동시 쓰기·트리거·타임존.
# ===========================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ---------- 반복 검증 모드 (RUNS>1) ----------
# 자기 자신을 N회 재실행해 종료코드로 자동판정하고 결과표를 누적한다.
if [ "${RUNS:-1}" -gt 1 ] && [ -z "${_VERIFY_CHILD:-}" ]; then
  # FORM: 결과표의 환경 이름 — 여러 CSP·실행 형태를 오가며 잰 결과를 한 표에서 비교하기 위한
  # 태그 (LexAI 병행 검증에서 이식). 예: FORM=aws-shell, FORM=gcp-shell, FORM=aws-docker
  FORM="${FORM:-shell-$INFRA_MODE}"
  HISTORY="$SCRIPT_DIR/verify-history.tsv"
  [ -f "$HISTORY" ] || printf '# 시각\t형태\t회차\t판정\t챗응답(s)\n' > "$HISTORY"
  PASS_RUNS=0
  for i in $(seq 1 "$RUNS"); do
    RUN_LOG="$LOG_DIR/verify-run-$i.log"
    if _VERIFY_CHILD=1 RUNS=1 "$0" > "$RUN_LOG" 2>&1; then R=PASS; PASS_RUNS=$((PASS_RUNS + 1)); else R=FAIL; fi
    # 챗 스모크가 돌았으면 응답 시간을 함께 기록 (콜드→웜 추세 확인용)
    ELAPSED="$(sed -n 's/.*응답 (\([0-9]*\)s).*/\1/p' "$RUN_LOG" | tail -1)"
    printf '%s\t%s\trun-%02d\t%s\t%s\n' "$(date '+%F %T')" "$FORM" "$i" "$R" "${ELAPSED:--}" | tee -a "$HISTORY"
  done
  echo
  log "반복 검증: $PASS_RUNS/$RUNS PASS — 결과표: $HISTORY (회차 로그: $LOG_DIR/verify-run-N.log)"
  [ "$PASS_RUNS" -eq "$RUNS" ] || die "연속 PASS 실패 ($PASS_RUNS/$RUNS) — FAIL 회차 로그 확인"
  exit 0
fi

PASS=0; FAIL=0
check() {  # $1=이름 $2=명령...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]   %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n' "$name"; FAIL=$((FAIL+1))
  fi
}

echo "== WidgetRAG 상태 점검 (INFRA_MODE=$INFRA_MODE) =="
# SQLite는 서버가 아니라 파일 — 백엔드 최초 기동 시 자동 생성된다
check "SQLite DB    ($SQLITE_DB_FILE)"   test -s "$SQLITE_DB_FILE"
check "OpenSearch   (:$PORT_OPENSEARCH)" curl -fsS --max-time 5 "http://localhost:$PORT_OPENSEARCH/_cluster/health"
check "Ollama       (:$PORT_OLLAMA)"     curl -fsS --max-time 5 "http://localhost:$PORT_OLLAMA/api/tags"
check "모델 $OLLAMA_MODEL"               sh -c "ollama list | awk '{print \$1}' | grep -Fqx '$OLLAMA_MODEL'"
check "AI 서버      (:$PORT_AI)"         curl -fsS --max-time 5 "http://localhost:$PORT_AI/docs"
check "백엔드       (:$PORT_BACKEND)"    curl -fsSL --max-time 10 "http://localhost:$PORT_BACKEND/swagger-ui.html"
check "프론트엔드   (:$PORT_FRONTEND)"   curl -fsS --max-time 5 "http://localhost:$PORT_FRONTEND/"

# ---------- SQLite 기능 등가성 (FK · WAL 동시 쓰기 · 트리거 · 설정) ----------
if [ -s "$SQLITE_DB_FILE" ] && command -v sqlite3 >/dev/null 2>&1; then
  echo
  echo "== SQLite 기능 등가성 (원본 RDB와의 등가 동작 확인) =="
  # FK 정합: 고아 행(참조 무결성 위반)이 없어야 한다 — 출력이 비어 있으면 통과
  check "FK 정합 (PRAGMA foreign_key_check)" \
    sh -c "[ -z \"\$(sqlite3 '$SQLITE_DB_FILE' 'PRAGMA foreign_key_check;')\" ]"
  # WAL 모드: 동시 읽기+쓰기의 전제 (JDBC URL의 journal_mode=WAL이 파일에 반영됐는지)
  check "WAL 모드 (PRAGMA journal_mode)" \
    sh -c "[ \"\$(sqlite3 '$SQLITE_DB_FILE' 'PRAGMA journal_mode;')\" = wal ]"
  # FK 강제 설정: SQLite는 커넥션마다 켜야 강제됨 — 앱 JDBC URL에 foreign_keys=true 필요
  LOCAL_YAML="$BACKEND_DIR/src/main/resources/application-local.yaml"
  if [ -f "$LOCAL_YAML" ]; then
    check "FK 강제 설정 (JDBC url foreign_keys=true)" grep -q 'foreign_keys=true' "$LOCAL_YAML"
  fi
  # 동시 쓰기: 두 프로세스가 동시에 써도 database is locked 없이 전부 반영돼야 한다
  # (WAL + busy_timeout 동작 검증 — 스크래치 테이블 사용 후 삭제, 서비스 데이터 무관)
  SCRATCH_OK=1
  sqlite3 "$SQLITE_DB_FILE" "CREATE TABLE IF NOT EXISTS _verify_scratch(k TEXT); DELETE FROM _verify_scratch;" 2>/dev/null || SCRATCH_OK=0
  if [ "$SCRATCH_OK" = 1 ]; then
    for w in 1 2; do
      ( for i in $(seq 1 25); do
          sqlite3 -cmd '.timeout 5000' "$SQLITE_DB_FILE" "INSERT INTO _verify_scratch VALUES('w$w-$i');" || exit 1
        done ) &
      eval "W${w}_PID=$!"
    done
    wait "$W1_PID"; W1_RC=$?
    wait "$W2_PID"; W2_RC=$?
    ROWS="$(sqlite3 "$SQLITE_DB_FILE" "SELECT count(*) FROM _verify_scratch;")"
    sqlite3 "$SQLITE_DB_FILE" "DROP TABLE IF EXISTS _verify_scratch;" 2>/dev/null
    check "동시 쓰기 (2 writer × 25행, busy_timeout)" \
      sh -c "[ $W1_RC -eq 0 ] && [ $W2_RC -eq 0 ] && [ '$ROWS' = 50 ]"
  else
    printf '  [FAIL] 동시 쓰기 — 스크래치 테이블 생성 실패 (DB 잠김?)\n'; FAIL=$((FAIL+1))
  fi
  # 트리거: 판정은 소스 값이 필요 — 기본은 정보 출력, EXPECT_TRIGGERS=<n> 지정 시 판정
  TRIGGERS="$(sqlite3 "$SQLITE_DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='trigger';")"
  if [ -n "${EXPECT_TRIGGERS:-}" ]; then
    check "트리거 수 일치 (소스=$EXPECT_TRIGGERS / 타겟=$TRIGGERS)" test "$TRIGGERS" = "$EXPECT_TRIGGERS"
  else
    printf '  [INFO] 트리거 수: %s (소스와 대조하려면 EXPECT_TRIGGERS=<소스 값> 지정)\n' "$TRIGGERS"
  fi
elif [ -s "$SQLITE_DB_FILE" ]; then
  warn "sqlite3 CLI 없음 — SQLite 기능 등가성 검증 생략 (sudo apt install sqlite3)"
fi

echo
echo "결과: 통과 $PASS / 실패 $FAIL"

# ---------- 선택: RAG 챗봇 스모크 테스트 ----------
if [ -n "${CLIENT_CODE:-}" ]; then
  QUESTION="${QUESTION:-가장 비싼 상품 추천해줘}"
  echo
  echo "== 챗봇 스모크 테스트 (clientCode=$CLIENT_CODE) =="
  echo "질문: $QUESTION"
  echo "(LLM 생성까지 최대 3분 대기 — CPU/Metal 환경은 수십 초 걸릴 수 있음)"
  START=$(date +%s)
  RESP=$(curl -fsS --max-time 200 -X POST "http://localhost:$PORT_BACKEND/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"clientCode\":\"$CLIENT_CODE\",\"question\":\"$QUESTION\"}") || { echo "[FAIL] /api/chat 호출 실패"; exit 1; }
  ELAPSED=$(( $(date +%s) - START ))
  echo "응답 (${ELAPSED}s):"
  echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

  # 타임존 검증: 방금 기록된 chat_log 생성시각이 지금 시각과 맞는지.
  # created_at은 타임존 무표기(LocalDateTime) — 저장 형식에 따라 비교 기준을 맞춘다:
  #   - epoch millis(정수, sqlite-jdbc 기본): UTC 절대값 → date +%s 와 직접 비교
  #   - TEXT(벽시계): VM 로컬 시각과 같은 기준으로 해석해 비교 (양쪽 다 UTC 해석 → 오프셋 상쇄)
  # 어긋나면 JVM/컨테이너/VM의 타임존 기준이 갈라진 것 — 이관 데이터와 신규 쓰기가 섞이면 시각이 뒤엉킨다.
  if [ -s "$SQLITE_DB_FILE" ] && command -v sqlite3 >/dev/null 2>&1; then
    RAW="$(sqlite3 "$SQLITE_DB_FILE" "SELECT MAX(created_at) FROM chat_log;" 2>/dev/null)"
    DB_TS=""; REF_TS=""
    case "$RAW" in
      "") : ;;                                    # 행 없음 — 검증 생략
      *[!0-9]*)                                   # TEXT 벽시계 (예: 2026-09-22 17:31:18)
        DB_TS="$(sqlite3 "$SQLITE_DB_FILE" "SELECT CAST(strftime('%s', '$RAW') AS INTEGER);" 2>/dev/null)"
        REF_TS="$(sqlite3 "$SQLITE_DB_FILE" "SELECT CAST(strftime('%s', datetime('now','localtime')) AS INTEGER);")"
        ;;
      *)                                          # 정수 epoch — 13자리 이상이면 millis
        if [ "${#RAW}" -ge 13 ]; then DB_TS=$((RAW / 1000)); else DB_TS="$RAW"; fi
        REF_TS="$(date +%s)"
        ;;
    esac
    if [ -n "$DB_TS" ] && [ -n "$REF_TS" ]; then
      DRIFT=$(( REF_TS - DB_TS )); [ "$DRIFT" -lt 0 ] && DRIFT=$(( -DRIFT ))
      if [ "$DRIFT" -lt 3600 ]; then
        printf '  [OK]   타임존 — chat_log 생성시각과 현재 시각 차 %ss (VM 타임존: %s)\n' "$DRIFT" "$(date '+%Z %z')"
      else
        printf '  [FAIL] 타임존 — chat_log 생성시각이 현재와 %ss 어긋남 (JVM·컨테이너·VM 타임존 대조: timedatectl, 소스와 통일)\n' "$DRIFT"
        FAIL=$((FAIL+1))
      fi
    fi
  fi
fi

[ "$FAIL" -eq 0 ]
