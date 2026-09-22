# main.py
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
from typing import List, Optional

import os
import requests

app = FastAPI(title="WidgetRAG AI Server")

# GPU가 없는 환경(로컬 CPU, CI)에서도 기동되도록 자동 판별합니다.
# 강제로 지정하려면 EMBEDDING_DEVICE=cuda|cpu
_device = os.getenv("EMBEDDING_DEVICE")
if not _device:
    import torch
    _device = "cuda" if torch.cuda.is_available() else "cpu"

embedding_model = SentenceTransformer("BAAI/bge-m3", device=_device)

# 컨테이너에서는 docker-compose 서비스명으로 주입됩니다 (예: http://llm:11434)
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/")
OLLAMA_URL = f"{OLLAMA_BASE_URL}/api/generate"

# Ollama 레지스트리 모델명. llm 컨테이너가 pull하는 모델과 일치해야 합니다.
# 기본 Gemma 3 4B — 라이선스(OLA 표기) 및 실증 내부안 기준. 교체는 OLLAMA_MODEL로.
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "gemma3:4b")

# 생성 파라미터 — 마이그레이션 동등성 검증은 "결정적 설정(temperature 0 + seed 고정)에서
# 동일 입력 → 결과 일치 비교"를 요구하므로, 환경변수와 요청 단위 양쪽에서 제어 가능해야 한다.
#   검증 모드 예: LLM_TEMPERATURE=0 LLM_SEED=42 (또는 요청 본문에 temperature/seed 지정)
LLM_TEMPERATURE = float(os.getenv("LLM_TEMPERATURE", "0.7"))
LLM_SEED = int(os.getenv("LLM_SEED")) if os.getenv("LLM_SEED") else None
LLM_NUM_PREDICT = int(os.getenv("LLM_NUM_PREDICT", "200"))


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedResponse(BaseModel):
    embeddings: List[List[float]]


class ProductContext(BaseModel):
    productName: str
    price: int
    category: str
    description: Optional[str] = None


class GenerateRequest(BaseModel):
    clientCode: str
    question: str
    products: List[ProductContext]
    # 동등성 검증용 요청 단위 오버라이드 — 미지정 시 서버 기본값(환경변수) 사용
    temperature: Optional[float] = None
    seed: Optional[int] = None


class GenerateResponse(BaseModel):
    answer: str

class EmbedBatchRequest(BaseModel):
    texts: List[str]

@app.post("/embed/batch")
def embed_batch(request: EmbedBatchRequest):
    embeddings = embedding_model.encode(
        request.texts,
        normalize_embeddings=True
    )
    return embeddings.tolist()


@app.get("/health")
def health_check():
    return {
        "status": "ok",
        "embedding_device": str(embedding_model.device),
        "llm_provider": "ollama",
        "llm_model": OLLAMA_MODEL,
        "llm_temperature": LLM_TEMPERATURE,
        "llm_seed": LLM_SEED
    }


@app.post("/embed", response_model=EmbedResponse)
def embed(request: EmbedRequest):
    embeddings = embedding_model.encode(
        request.texts,
        normalize_embeddings=True
    )
    return EmbedResponse(embeddings=embeddings.tolist())


@app.post("/generate", response_model=GenerateResponse)
def generate(request: GenerateRequest):
    product_lines = "\n".join([
        f"{i+1}. {p.productName} │ {p.price:,}원 │ {p.category}"
        + (f" │ {p.description}" if p.description else "")
        for i, p in enumerate(request.products)
    ])

    prompt = f"""당신은 {request.clientCode} 쇼핑몰의 상품 추천 챗봇입니다.
아래 제공된 상품 목록 안에서만 답변하세요. 목록에 없는 상품은 절대 추천하지 마세요.

[검색된 상품 목록]
{product_lines}

[사용자 질문]
{request.question}

[답변 형식]
위 상품 중 질문과 가장 관련 있는 상품을 1~2개 골라 상품명과 가격을 포함해 자연스러운 한국어 문장으로 답변하세요."""

    temperature = request.temperature if request.temperature is not None else LLM_TEMPERATURE
    seed = request.seed if request.seed is not None else LLM_SEED

    options = {
        "temperature": temperature,
        "num_predict": LLM_NUM_PREDICT
    }
    if seed is not None:
        options["seed"] = seed

    response = requests.post(
        OLLAMA_URL,
        json={
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": options
        },
        timeout=180
    )

    response.raise_for_status()
    answer = response.json().get("response", "")

    return GenerateResponse(answer=answer.strip())