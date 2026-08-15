# WidgetRag - llm (Ollama + EXAONE 3.5 7.8B)
#
# Ollama 공식 레지스트리의 exaone3.5:7.8b를 그대로 사용합니다.
# 프롬프트 템플릿/stop 토큰은 모델에 내장되어 있으므로 Modelfile이 필요 없습니다.
#
# 모델 가중치(약 5GB)는 이미지에 굽지 않고 ollama-data 볼륨에 받습니다.
# → 이미지는 가볍게 유지되고, 컨테이너를 다시 만들어도 재다운로드가 없습니다.
#
# GPU 필요: 호스트에 nvidia-container-toolkit이 설치되어 있어야 합니다.

FROM ollama/ollama:latest

COPY ./entrypoint.sh /entrypoint.sh

# Windows에서 체크아웃한 경우 CRLF 때문에 실행이 실패하는 것을 방지합니다.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV OLLAMA_HOST=0.0.0.0 \
    OLLAMA_MODEL=exaone3.5:7.8b

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=5 \
    CMD ollama list > /dev/null 2>&1 || exit 1

# 베이스 이미지의 ENTRYPOINT(/bin/ollama)와 CMD(serve)를 모두 무력화합니다.
ENTRYPOINT ["/entrypoint.sh"]
CMD []
