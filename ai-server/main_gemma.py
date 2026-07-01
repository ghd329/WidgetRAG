# main.py (전체)
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
from transformers import AutoModelForCausalLM, AutoTokenizer
import torch
from typing import List, Optional

app = FastAPI(title="WidgetRAG AI Server")

# 임베딩 모델 (서버 시작 시 한 번만 로드)
embedding_model = SentenceTransformer("BAAI/bge-m3", device="cuda")

# Gemma 모델 (서버 시작 시 한 번만 로드)
GEMMA_MODEL_ID = "google/gemma-3-4b-it"
gemma_tokenizer = AutoTokenizer.from_pretrained(GEMMA_MODEL_ID)
gemma_model = AutoModelForCausalLM.from_pretrained(
    GEMMA_MODEL_ID,
    torch_dtype=torch.bfloat16,
    device_map="auto"
)


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


@app.get("/health")
def health_check():
    return {
        "status": "ok",
        "embedding_device": str(embedding_model.device),
        "gemma_device": str(gemma_model.device)
    }


@app.post("/embed", response_model=EmbedResponse)
def embed(request: EmbedRequest):
    embeddings = embedding_model.encode(request.texts, normalize_embeddings=True)
    return EmbedResponse(embeddings=embeddings.tolist())


@app.post("/generate", response_model=GenerateResponse)
def generate(request: GenerateRequest):
    # 모델정의서 3.5 프롬프트 템플릿
    product_lines = "\n".join([
        f"{i+1}. {p.productName} │ {p.price:,}원 │ {p.category}"
        + (f" │ {p.description}" if p.description else "")
        for i, p in enumerate(request.products)
    ])

    prompt = f"""당신은 {request.clientCode} 쇼핑몰의 상품 추천 챗봇입니다.
아래 제공된 상품 목록 안에서만 답변하세요. 목록에 없는 상품은 추천하지 마세요.

[검색된 상품 목록]
{product_lines}

[사용자 질문]
{request.question}

[답변 형식]
위 상품 중 질문과 가장 관련 있는 상품을 1~2개 골라 이름과 가격을 함께 자연스러운 한국어 문장으로 제시하세요."""

    messages = [{"role": "user", "content": prompt}]

    inputs = gemma_tokenizer.apply_chat_template(
        messages,
        return_tensors="pt",
        add_generation_prompt=True,
        return_dict=True
    ).to(gemma_model.device)

    outputs = gemma_model.generate(**inputs, max_new_tokens=200, temperature=0.7)

    # 입력 프롬프트 부분을 제외하고 새로 생성된 답변만 추출
    generated_tokens = outputs[0][inputs["input_ids"].shape[1]:]
    answer = gemma_tokenizer.decode(generated_tokens, skip_special_tokens=True)

    return GenerateResponse(answer=answer.strip())