# WidgetRag - ai-server (FastAPI / bge-m3 임베딩 / EXAONE는 Ollama HTTP로 호출)
# main_exaone.py + requirements_exaone.txt 기준 (main_gemma.py는 미사용)
#
# GPU 필요: requirements_exaone.txt의 torch는 PyPI 기본 휠(CUDA 빌드)이라
#          nvidia CUDA 런타임 라이브러리가 휠 안에 포함되어 있습니다.
#          따라서 nvidia/cuda 베이스 이미지는 불필요하고, 실행 시
#          nvidia-container-toolkit + `--gpus all`(compose는 deploy.resources)만 있으면 됩니다.
#          GPU 없이 띄우면 EMBEDDING_DEVICE=cpu로 자동 폴백되지만 임베딩이 매우 느립니다.
#
# 이미지 크기는 torch(CUDA) 때문에 6~7GB 수준입니다.

FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements_exaone.txt .
RUN pip install --no-cache-dir -r requirements_exaone.txt

# bge-m3(약 2.3GB)를 빌드 시점에 미리 받아둡니다.
# 이게 없으면 첫 요청 때 다운로드가 일어나 콜드스타트가 수 분 걸리고,
# 런타임에 HuggingFace 접속이 불가능한 환경에서는 아예 실패합니다.
ENV HF_HOME=/opt/hf-cache
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('BAAI/bge-m3')"

COPY main_exaone.py .

ENV OLLAMA_BASE_URL=http://llm:11434 \
    OLLAMA_MODEL=exaone3.5:7.8b

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
    CMD curl -fsS http://localhost:8000/health > /dev/null || exit 1

CMD ["uvicorn", "main_exaone:app", "--host", "0.0.0.0", "--port", "8000"]
