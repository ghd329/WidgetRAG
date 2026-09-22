#!/usr/bin/env bash
# ===========================================================
# 전체 종료 — 기동의 역순. 데이터(DB·색인·모델)는 모두 유지된다.
#
#   사용법:
#     ./90-stop-all.sh              # 앱 + Ollama + 컨테이너 + Colima VM 까지 종료
#     ./90-stop-all.sh --keep-vm    # Colima VM은 켜둔 채 나머지만 종료
#
#   ⚠️ 데이터까지 초기화하려면 (재가입·CSV 재업로드 필요해짐):
#     docker rm -f widgetrag-opensearch && rm -f ~/widgetrag-data/widgetrag.db*
# ===========================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ---------- 1. 앱 계층 (역순: 프론트 → 백엔드 → AI 서버) ----------
if [ "$OS" = "Linux" ]; then
  # systemd 유닛으로 기동된 앱 3종 중지 (40-start-apps.sh의 Linux 경로와 대응)
  for unit in widgetrag-frontend widgetrag-backend widgetrag-ai; do
    sudo systemctl stop "$unit" 2>/dev/null && log "$unit 중지" || true
  done
fi
# macOS(nohup) 또는 구버전 스크립트로 띄운 프로세스 정리
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
if [ "$OS" = "Darwin" ]; then
  brew services stop ollama >/dev/null 2>&1 && log "Ollama 서비스 중지" || true
else
  # systemd(ollama 유저)가 기본 — 실패 시 nohup 폴백으로 띄운 자기 소유 프로세스만 정리
  sudo systemctl stop ollama 2>/dev/null || pkill -x ollama 2>/dev/null || true
fi

# ---------- 3. 인프라 (데이터 유지) ----------
# SQLite는 백엔드 프로세스에 내장 — 백엔드 종료로 함께 정리되며 DB 파일은 유지된다
if [ "$INFRA_MODE" = "native" ]; then
  sudo systemctl stop opensearch 2>/dev/null && log "네이티브 OpenSearch 중지 (색인 유지)" || true
else
  docker stop "$OS_CONTAINER" >/dev/null 2>&1 && log "컨테이너 중지 (데이터 유지)" || true
fi

# ---------- 4. Colima VM ----------
if [ "$OS" = "Darwin" ] && [ "${1:-}" != "--keep-vm" ]; then
  colima stop && log "Colima VM 중지 (메모리 반환)"
fi

# ---------- 5. 종료 확인 ----------
# port_listening(ss 기반)으로 확인 — lsof는 Linux에서 타 유저(opensearch 등) 소켓을 못 봐
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
