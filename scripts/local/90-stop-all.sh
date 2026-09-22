#!/usr/bin/env bash
# ===========================================================
# 전체 종료 — 기동의 역순. 데이터(DB·색인·모델)는 모두 유지된다.
#
#   사용법:
#     ./90-stop-all.sh
#
#   ⚠️ 데이터까지 초기화하려면(완전 삭제 후 복구 리허설): ./91-wipe-data.sh --yes
# ===========================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ---------- 1. 앱 계층 (역순: 프론트 → 백엔드 → AI 서버) ----------
for unit in widgetrag-frontend widgetrag-backend widgetrag-ai; do
  sudo systemctl stop "$unit" 2>/dev/null && log "$unit 중지" || true
done
# 구버전 스크립트(nohup)로 띄운 프로세스 잔재 정리
kill_pidfile frontend
kill_pidfile backend
kill_pidfile ai-server

# pid 파일이 없거나 수동으로 띄운 프로세스가 남아 있으면 포트 기준으로 정리
for port in "$PORT_FRONTEND" "$PORT_BACKEND" "$PORT_AI"; do
  if port_listening "$port"; then
    warn "포트 :$port 프로세스 잔존 — 강제 종료"
    kill "$(lsof -ti tcp:"$port")" 2>/dev/null || true
  fi
done

# ---------- 2. Ollama ----------
# systemd(ollama 유저)가 기본 — 실패 시 nohup 폴백으로 띄운 자기 소유 프로세스만 정리
sudo systemctl stop ollama 2>/dev/null || pkill -x ollama 2>/dev/null || true

# ---------- 3. OpenSearch (데이터 유지) ----------
# SQLite는 백엔드 프로세스에 내장 — 백엔드 종료로 함께 정리되며 DB 파일은 유지된다
sudo systemctl stop opensearch 2>/dev/null && log "OpenSearch 중지 (색인 유지)" || true

# ---------- 4. 종료 확인 ----------
# port_listening(ss 기반)으로 확인 — lsof는 타 유저(opensearch 등) 소켓을 못 봐
# systemd stop이 조용히 실패해도 "종료 완료"로 거짓 보고할 수 있음 (2026-09-22 검토에서 수정)
echo
REMAIN=""
for port in "$PORT_FRONTEND" "$PORT_BACKEND" "$PORT_AI" \
            "$PORT_OPENSEARCH" "$PORT_OLLAMA"; do
  port_listening "$port" && REMAIN="$REMAIN :$port"
done
if [ -z "$REMAIN" ]; then
  log "전체 종료 완료 — 리슨 중인 포트 없음"
else
  warn "아직 리슨 중인 포트가 있음 —$REMAIN"
fi
