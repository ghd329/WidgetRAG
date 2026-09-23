#!/usr/bin/env bash
# ===========================================================
# WidgetRAG — Docker Compose(B) 볼륨 이관 스크립트 (export / import)
#
#   scripts/compose/deploy.sh 와 짝 — 저장소에 있지만 타겟은 clone하지 않고
#   이 파일만 raw로 받아 쓴다. B 트랙의 상태 데이터인 네임드 볼륨을 아카이브로
#   내보내고, 타겟에서 해시 검증 후 복원한다.
#   이관 리허설 절차서 5절(수동 볼륨 아카이브)의 자동화 구현.
#
#   수신 (deploy.sh와 동일하게 디스크 사본으로 — 파이프 실행 금지):
#     curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/compose/volume-migrate.sh -o volume-migrate.sh
#
#   대상 볼륨 (compose 프로젝트 접두어 자동 부착):
#     upload-data      SQLite DB + 업로드 CSV   — 항상 포함
#     opensearch-data  색인                     — 항상 포함
#     ollama-data      LLM 모델(3.3GB)          — WITH_MODEL=1 일 때만 (재다운로드 가능해 기본 제외)
#     (caddy-data/config 는 재생성 가능 — 제외)
#
#   사용법:
#     [소스] bash volume-migrate.sh export [출력디렉토리]     # 기본: ~/widgetrag-exports
#            OBJECT_STORAGE_URI=s3://bucket/widgetrag bash volume-migrate.sh export
#     [타겟] bash volume-migrate.sh import <번들디렉토리 | s3://...번들prefix>
#            FORCE=1 …  import   # 타겟 볼륨에 기존 데이터가 있어도 비우고 복원
#
#   전제: export/import 모두 해당 compose 프로젝트의 컨테이너가 전부 정지 상태여야 한다
#         (cd ~/widgetrag-deploy && sudo docker compose down — 볼륨은 유지됨).
#         SQLite 정합성: backend 정상 종료 시 WAL이 체크포인트된 상태로 볼륨에 남는다.
#   환경변수: COMPOSE_PROJECT (기본 widgetrag-deploy — 배포 디렉토리명과 동일해야 함)
# ===========================================================
set -euo pipefail

# 파이프 실행 차단 — curl | bash 로 오면 BASH_SOURCE가 실파일이 아니다
if [ ! -f "${BASH_SOURCE[0]:-}" ]; then
  printf '\033[1;31m[volume-migrate][FAIL]\033[0m 파이프 실행 금지 — 파일로 받아 실행하세요: curl -fsSL <raw URL> -o volume-migrate.sh && bash volume-migrate.sh\n' >&2
  exit 1
fi

MODE="${1:-}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-widgetrag-deploy}"
VOLUMES=(upload-data opensearch-data)
[ "${WITH_MODEL:-}" = "1" ] && VOLUMES+=(ollama-data)

log() { printf '\033[1;32m[volume-migrate]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[volume-migrate][WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[volume-migrate][FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "타겟/소스 VM(Ubuntu Linux) 전용 스크립트입니다"
sudo docker info >/dev/null 2>&1 || die "Docker 데몬에 연결 불가"

# 컨테이너 정지 확인 — 실행 중 볼륨을 뜨면 SQLite WAL·색인 정합성이 깨진다
RUNNING="$(sudo docker ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT")"
[ -z "$RUNNING" ] || die "프로젝트($COMPOSE_PROJECT) 컨테이너가 실행 중 — 먼저: cd ~/$COMPOSE_PROJECT && sudo docker compose down"

vol_full() { echo "${COMPOSE_PROJECT}_$1"; }

case "$MODE" in
# ===========================================================
export)
  OUT_ROOT="${2:-$HOME/widgetrag-exports}"
  TS="$(date +%Y%m%d%H%M%S)"
  BUNDLE="widgetrag-volumes-$TS"
  OUT="$OUT_ROOT/$BUNDLE"
  mkdir -p "$OUT"

  for vol in "${VOLUMES[@]}"; do
    FULL="$(vol_full "$vol")"
    sudo docker volume inspect "$FULL" >/dev/null 2>&1 || die "볼륨 없음: $FULL (COMPOSE_PROJECT 확인)"
    log "볼륨 아카이브: $FULL → $vol.tgz"
    sudo docker run --rm -v "$FULL":/from -v "$OUT":/to alpine tar -czf "/to/$vol.tgz" -C /from .
  done
  sudo chown -R "$USER" "$OUT"

  ( cd "$OUT" && sha256sum ./*.tgz > SHA256SUMS )
  {
    echo "# WidgetRAG B트랙 볼륨 번들 — $TS"
    echo "# 프로젝트: $COMPOSE_PROJECT · 볼륨: ${VOLUMES[*]}"
    ( cd "$OUT" && du -h ./*.tgz )
  } > "$OUT/MANIFEST"

  log "내보내기 완료: $OUT"
  cat "$OUT/MANIFEST"

  if [ -n "${OBJECT_STORAGE_URI:-}" ]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI 필요"
    log "오브젝트 스토리지 업로드: $OBJECT_STORAGE_URI/$BUNDLE/"
    aws s3 cp --recursive "$OUT" "$OBJECT_STORAGE_URI/$BUNDLE/"
    echo
    log "타겟에서: bash volume-migrate.sh import $OBJECT_STORAGE_URI/$BUNDLE"
  else
    echo
    log "업로드 생략 — 타겟에서: bash volume-migrate.sh import <이 디렉토리>"
  fi
  ;;
# ===========================================================
import)
  SRC="${2:-}"
  [ -n "$SRC" ] || die "사용법: $0 import <번들디렉토리 또는 s3://...번들prefix>"

  case "$SRC" in
    s3://*)
      command -v aws >/dev/null 2>&1 || die "aws CLI 필요"
      WORK="$HOME/widgetrag-imports/$(basename "$SRC")"
      mkdir -p "$WORK"
      log "오브젝트 스토리지에서 다운로드: $SRC → $WORK"
      aws s3 cp --recursive "$SRC" "$WORK"
      SRC="$WORK"
      ;;
  esac
  [ -f "$SRC/SHA256SUMS" ] || die "SHA256SUMS 없음: $SRC (export 산출 번들 디렉토리를 지정)"

  log "아카이브 해시 검증"
  ( cd "$SRC" && sha256sum -c SHA256SUMS --quiet ) || die "해시 불일치 — 전송 중 손상"
  log "해시 전체 일치"

  for tgz in "$SRC"/*.tgz; do
    vol="$(basename "$tgz" .tgz)"
    FULL="$(vol_full "$vol")"
    if sudo docker volume inspect "$FULL" >/dev/null 2>&1; then
      # 기존 데이터가 있으면 실수 방지를 위해 FORCE=1 요구 (볼륨은 파일처럼 백업해두기 어렵다)
      HAS_DATA="$(sudo docker run --rm -v "$FULL":/v alpine sh -c 'ls -A /v | head -1')"
      if [ -n "$HAS_DATA" ]; then
        [ "${FORCE:-}" = "1" ] || die "볼륨 $FULL 에 기존 데이터 있음 — 덮어쓰려면 FORCE=1 지정"
        warn "FORCE=1 — $FULL 기존 내용 삭제 후 복원"
        sudo docker run --rm -v "$FULL":/v alpine sh -c 'rm -rf /v/* /v/..?* /v/.[!.]* 2>/dev/null || true'
      fi
    else
      sudo docker volume create "$FULL" >/dev/null
    fi
    log "볼륨 복원: $vol.tgz → $FULL"
    sudo docker run --rm -v "$FULL":/to -v "$SRC":/from alpine tar -xzf "/from/$vol.tgz" -C /to
  done

  echo
  log "복원 완료 — 기동: IMAGE_TAG=<태그> bash deploy.sh (scripts/compose/deploy.sh — raw 수신)"
  log "  (배포 스크립트가 볼륨을 그대로 물고 올라온다 — 기동 후 색인·데이터 건수 대조로 동등성 확인)"
  ;;
# ===========================================================
*)
  die "사용법: $0 export [출력디렉토리] | $0 import <번들디렉토리|s3://...> (모델 포함: WITH_MODEL=1)"
  ;;
esac
