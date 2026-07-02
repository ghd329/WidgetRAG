# main.py
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
from typing import List, Optional

import requests

app = FastAPI(title="WidgetRAG AI Server")

embedding_model = SentenceTransformer("BAAI/bge-m3", device="cuda")

OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_MODEL = "exaone3.5:7.8b"   # 여기만 바꾸면 모델 교체 가능


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


class GenerateResponse(BaseModel):
    answer: str

class EmbedBatchRequest(BaseModel):
    texts: List[str]

@app.post("/embed/batch")
def embed_batch(request: EmbedBatchRequest):
    vectors = []

    for text in request.texts:
        vector = embed_text(text)
        vectors.append(vector)

    return vectors


@app.get("/health")
def health_check():
    return {
        "status": "ok",
        "embedding_device": str(embedding_model.device),
        "llm_provider": "ollama",
        "llm_model": OLLAMA_MODEL
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

    response = requests.post(
        OLLAMA_URL,
        json={
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": 0.7,
                "num_predict": 200
            }
        },
        timeout=180
    )

    response.raise_for_status()
    answer = response.json().get("response", "")

    return GenerateResponse(answer=answer.strip())