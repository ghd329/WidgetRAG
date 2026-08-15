#!/bin/sh
# Ollama를 띄우고 EXAONE 3.5 모델을 확보합니다.
#
# 모델은 이미지가 아니라 /root/.ollama 볼륨에 저장됩니다.
#  - 이미지가 가벼워지고, 재배포해도 다시 받지 않습니다.
#  - 최초 1회만 약 5GB를 내려받습니다(수 분 소요).
# ollama pull은 이미 받은 모델이면 즉시 통과하므로 매 기동마다 호출해도 안전합니다.
set -e

MODEL_NAME="${OLLAMA_MODEL:-exaone3.5:7.8b}"

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
echo "[llm] 준비 완료 — 요청 대기"

wait "$SERVE_PID"
