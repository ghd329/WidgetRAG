from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
from typing import List

app = FastAPI(title="WidgetRAG AI Server")

# 서버 시작 시 한 번만 모델 로드 (요청마다 로드하면 매번 몇 초씩 걸림)
embedding_model = SentenceTransformer("BAAI/bge-m3", device="cuda")


class EmbedRequest(BaseModel):
    texts: List[str]


class EmbedResponse(BaseModel):
    embeddings: List[List[float]]


@app.get("/health")
def health_check():
    return {"status": "ok", "device": str(embedding_model.device)}


@app.post("/embed", response_model=EmbedResponse)
def embed(request: EmbedRequest):
    embeddings = embedding_model.encode(request.texts, normalize_embeddings=True)
    return EmbedResponse(embeddings=embeddings.tolist())