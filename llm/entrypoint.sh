#!/bin/sh
# Ollama를 띄우고 LLM 모델(기본 Gemma 3 4B)을 확보합니다.
#
# 모델은 이미지가 아니라 /root/.ollama 볼륨에 저장됩니다.
#  - 이미지가 가벼워지고, 재배포해도 다시 받지 않습니다.
#  - 최초 1회만 약 3.3GB를 내려받습니다(수 분 소요).
# ollama pull은 이미 받은 모델이면 즉시 통과하므로 매 기동마다 호출해도 안전합니다.
set -e

MODEL_NAME="${OLLAMA_MODEL:-gemma3:4b}"

ollama serve &
SERVE_PID=$!

echo "[llm] ollama 기동 대기..."
i=0
until ollama list > /dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "[llm] ollama 기동 실패 (60초 초과)" >&2
        exit 1
    fi
    sleep 1
done
echo "[llm] ollama 준비 완료"

echo "[llm] 모델 확보: ${MODEL_NAME}"
ollama pull "$MODEL_NAME"

# 모델 예열 — VRAM 에 미리 올려 둔다 (keep_alive 는 compose 의 OLLAMA_KEEP_ALIVE, 기본 24h).
# 첫 질문에 붙던 적재 시간(실측 32~85초)을 기동 쪽으로 옮기고, 대량 임베딩 뒤에 모델이 CPU 로 밀리지 않게 한다.
# 이미지에 curl 이 없어 CLI 로 짧은 생성을 한 번 돌린다 — 앱 DB 와 무관한 직접 호출이다.
echo "[llm] 모델 예열: ${MODEL_NAME}"
if ollama run "$MODEL_NAME" --keepalive "${OLLAMA_KEEP_ALIVE:-24h}" "ok" >/dev/null 2>&1; then
    echo "[llm] 모델 예열 완료"
else
    echo "[llm] 모델 예열 실패 — 첫 질문에 적재 시간이 붙는다" >&2
fi
echo "[llm] 준비 완료 — 요청 대기"

wait "$SERVE_PID"
