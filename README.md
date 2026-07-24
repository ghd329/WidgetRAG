# WidgetRAG — 원라인 임베드형 RAG 챗봇 SaaS 플랫폼

> **Widget** + **RAG** — 쇼핑몰에 스크립트 한 줄만 추가하면, 자사 상품 데이터 기반으로 답하는 AI 챗봇이 붙는 멀티테넌트 플랫폼

![Java](https://img.shields.io/badge/Java-17-ED8B00?style=flat-square&logo=openjdk&logoColor=white)
![Spring Boot](https://img.shields.io/badge/Spring_Boot-4.1.0-6DB33F?style=flat-square&logo=springboot&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=flat-square&logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-Embedding_%26_LLM-009688?style=flat-square&logo=fastapi&logoColor=white)
![OpenSearch](https://img.shields.io/badge/OpenSearch-k--NN_Vector_Search-005EB8?style=flat-square&logo=opensearch&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Database-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Ollama](https://img.shields.io/badge/Ollama-EXAONE_3.5-000000?style=flat-square)

---

## 📌 프로젝트 개요

WidgetRAG는 온라인 쇼핑몰 운영사가 **`<script>` 태그 한 줄**만 자신의 사이트에 삽입하면, 자사의 상품 데이터(CSV 업로드)를 기반으로 답변하는 AI 상품 추천 챗봇을 즉시 사용할 수 있게 해주는 **멀티테넌트 RAG(검색 증강 생성) 챗봇 SaaS**입니다.

여러 쇼핑몰(테넌트)의 상품 데이터가 하나의 벡터 인덱스에 공존하는 구조이기 때문에, 검색 단계에서 `client_code` 기반 데이터 격리를 강제하는 것이 설계의 핵심입니다. 실제 데모로 다이소몰·66girls 쇼핑몰을 크롤링해 만든 클론 사이트에 위젯을 임베드해 end-to-end로 동작을 검증했습니다.

| 항목 | 내용 |
|------|------|
| 서비스명 | WidgetRAG |
| 개발 유형 | 멀티테넌트 RAG 챗봇 SaaS (임베드 위젯 + 관리자 콘솔 + AI 서버) |
| 핵심 기능 | 원라인 위젯 임베드, CSV 상품 데이터 업로드·증분 적재, 벡터 검색 기반 RAG 답변, 회사/직원 승인 워크플로우 |
| 데모 대상 | 다이소몰, 66girls(패션몰) — 실제 사이트를 크롤링해 만든 클론 데모 샵 |
| 주요 기술 | Spring Boot 4, FastAPI, OpenSearch k-NN, BAAI/bge-m3, EXAONE 3.5 / Gemma 3 |

---

## 🏗️ 시스템 아키텍처

```
[고객 쇼핑몰 페이지]  ← <script src=".../widget.js" data-client-code="daiso">
    │  질문 입력
    ▼
[widget.js]  (Spring Boot 정적 리소스로 서빙되는 임베드형 위젯, 순수 JS IIFE)
    │  POST /api/chat  { clientCode, question }
    ▼
[Spring Boot Backend] :8080  (com.widgetrag.backend)
  ├─ chat        — ChatService: 검색 → LLM 호출 → Fallback 판단 → ChatLog 적재
  ├─ search       — OpenSearchIndexService / AiServerClient: 임베딩·k-NN 검색·인덱싱
  ├─ product      — CSV 업로드(preview/confirm), 증분 upsert, 상품 CRUD
  ├─ company      — 회사 가입/승인, 클라이언트 코드 발급
  ├─ member       — 회원가입/로그인(Session 기반), 직원 승인
  └─ widget       — 임베드 스크립트 태그 발급 API
    │
    ├──HTTP──▶ [OpenSearch] :9200
    │            product_items_exaone_test 인덱스, chunk_vector(dim=1024, HNSW, cosine)
    │            client_code term filter로 테넌트별 검색 격리
    │
    └──HTTP──▶ [AI Server] :8000  (FastAPI, ai-server/main_*.py)
                 ├─ /embed, /embed/batch  — BAAI/bge-m3 (SentenceTransformer, CUDA)
                 └─ /generate             — LLM 라우팅 (택1)
                       ├─ Ollama + EXAONE 3.5 7.8B  (외부 프로세스 호출)
                       └─ Gemma 3 4B-IT              (transformers, in-process, bfloat16)

[데이터 수집]
  data-pipeline/crawling/{daiso,fashion}  — Selenium/BeautifulSoup 크롤러
      └─ CSV 생성 → 회사 관리자 콘솔에서 수동 업로드 → 위 파이프라인으로 유입
```

---

## 🔧 기술 스택

### Backend
| 항목 | 내용 |
|------|------|
| 프레임워크 | Spring Boot 4.1.0 (Java 17), `spring-boot-starter-webmvc` |
| 인증 | Spring Security (BCrypt) + **세션 기반 인증** (JWT 미사용, `HttpSession` 속성으로 로그인 상태 관리) |
| ORM/DB | Spring Data JPA + PostgreSQL, `ddl-auto: update` |
| 벡터 검색 | `opensearch-java` / `opensearch-rest-client` 3.5.0 — k-NN(HNSW, cosine) 벡터 인덱스 |
| CSV 처리 | Apache Commons CSV 1.14.1 (BOM 대응, 컬럼 매핑 저장/재사용) |
| 문서화 | springdoc-openapi (Swagger UI) |

### AI Server
| 항목 | 내용 |
|------|------|
| 프레임워크 | FastAPI + Uvicorn |
| 임베딩 모델 | `BAAI/bge-m3` (SentenceTransformer, 1024차원, CUDA) |
| LLM (옵션 A) | **EXAONE 3.5 7.8B** — Ollama 로컬 서버 경유 호출 |
| LLM (옵션 B) | **Gemma 3 4B-IT** — `transformers`로 in-process 로드 (bfloat16, GPU 오토 배치) |
| 프롬프트 설계 | "검색된 상품 목록 안에서만 답변" 제약 프롬프트 — 할루시네이션 가드레일 |

### Data Pipeline
| 항목 | 내용 |
|------|------|
| 크롤링 | Selenium(동적 렌더링) + Requests/BeautifulSoup(정적 파싱) 하이브리드 |
| 대상 | 다이소몰(Selenium 필요), 66girls 패션몰(정적 HTML) |
| 안정성 | robots.txt Crawl-delay 준수, 진행상태 체크포인트 저장(재개 가능), 드라이버 주기적 재시작 |

### Frontend
| 항목 | 내용 |
|------|------|
| 구성 | 순수 HTML/CSS/JS (빌드 도구·프레임워크 없음) |
| 화면군 | admin(플랫폼 관리), company(테넌트 관리자 콘솔), customer(챗봇 데모), login, demo-shop(크롤링 클론 데모) |
| 위젯 | `widget.js` — 플로팅 챗 버블 UI, 답변 + 상품 추천 카드 렌더링을 담당하는 자체완결형 스크립트 |

---

## 🧠 핵심 기능 & 설계 포인트

### 1. 멀티테넌트 벡터 검색 격리
모든 상품 청크는 하나의 OpenSearch 인덱스에 함께 저장되지만, 검색 시 `client_code` term filter를 k-NN 쿼리에 결합해 **테넌트 간 데이터가 절대 섞이지 않도록 격리**했습니다. (`OpenSearchIndexService.search`)

### 2. CSV 증분 업로드 파이프라인
상품 CSV를 업로드하면 미리보기 → 컬럼 매핑 확인 → 확정의 2단계 플로우를 거치며, 확정 시점에는 기존 상품과 신규 데이터를 diff하여 **변경/신규 항목만 재임베딩·재인덱싱**합니다. 각 단계(파싱/조회/병합/DB저장/임베딩+색인)의 소요 시간을 계측 로그로 남겨, 실제로 이 로그를 근거로 대용량 업로드 시 발생한 타임아웃 문제를 진단하고 수정했습니다.

### 3. 성능 최적화 — CSV 업로드 파이프라인 병렬화

동일 데이터셋(daiso 상품 12,090개) 기준, 순차 처리와 병렬 처리를 계측 로그로 직접 비교했습니다. 순차 처리는 초기 계측 단계라 "CSV 파싱+DB 저장", "임베딩+색인" 2개 구간으로만 로깅했고, 병목 구간(임베딩+색인)을 특정한 뒤 병렬화를 적용하면서 5단계로 세분화해 다시 계측했습니다.

**순차 처리**

| 작업 | 소요 시간 |
|------|-----------|
| CSV 파싱 + DB 저장 | 6분 25.353초 (385,353ms) |
| 임베딩 + OpenSearch 색인 | 27분 32.244초 (1,652,244ms) |
| **전체 소요 시간** | **33분 58.912초 (2,038,912ms)** |

**병렬 처리**

| 작업 | 소요 시간 |
|------|-----------|
| CSV 파싱 | 0.269초 |
| 기존 상품 조회(DB) | 0.677초 |
| 병합/비교 로직 | 0.031초 |
| DB 저장(`saveAllAndFlush`) | 39.499초 |
| 임베딩 + OpenSearch 배치 색인 | 15분 32.170초 |
| **전체 소요 시간** | **16분 12.646초 (972,646ms)** |

**약 52.3% 단축.** 계측 결과 전체 처리 시간의 약 95.8%가 임베딩 + OpenSearch 배치 색인 구간에 집중되어 있음을 확인했고, 이 구간을 병목으로 특정해 병렬화를 적용했습니다.

### 4. 장애 대응 Fallback 정책
AI 서버(GPU 인퍼런스)가 느리거나 다운되어 있을 때, 또는 검색 결과가 0건일 때 예외를 그대로 전파하지 않고 **정해진 안내 응답으로 우아하게 대체**합니다. 모든 문답은 fallback 여부와 함께 회사별 `ChatLog`에 적재되어 이후 품질 분석에 활용할 수 있습니다.

### 5. 원라인 임베드 위젯
고객사는 `<script src=".../widget.js" data-client-code="...">` 한 줄만 자사 페이지에 추가하면 됩니다. 실제로 다이소몰·66girls를 크롤링해 만든 클론 데모 페이지에 이 위젯을 임베드하여, 실사이트에 가까운 환경에서 상품 추천 카드 렌더링까지 end-to-end로 검증했습니다.

### 6. 두 가지 LLM 백엔드 실험
동일한 RAG 파이프라인 위에서 **Ollama로 서빙하는 EXAONE 3.5**(외부 프로세스, 가벼운 운영)와 **transformers로 직접 로드하는 Gemma 3**(in-process, 세밀한 제어) 두 방식을 비교 구현하여, 운영 방식에 따른 트레이드오프(배포 용이성 vs 제어 유연성)를 직접 실험했습니다.

### 7. 회사/직원 승인 워크플로우
`client_code`는 회사 가입(`MemberService.signup()`) 시점에 즉시 생성되어 응답으로 반환되며, 플랫폼 관리자의 승인은 `CompanyStatus`를 PENDING→APPROVED로 전환해 계정을 활성화하는 역할입니다. 즉 승인은 client_code 발급 자체를 막는 게이트가 아니라, 승인 전까지는 로그인/서비스 이용이 제한되는 계정 활성화 절차입니다. 회사 내 직원 추가도 회사 관리자의 승인을 거치는 구조로, 전체적으로 2단계 권한 체계를 구현했습니다.

---

## 📁 프로젝트 구조

```
WidgetRAG/
├── backend/                                # Spring Boot 4 (Java 17)
│   └── src/main/java/com/widgetrag/backend/
│       ├── chat/        # 챗봇 Q&A, Fallback 정책, ChatLog
│       ├── search/      # OpenSearch 색인/검색, AI 서버 연동 클라이언트
│       ├── product/     # 상품/상품파일, CSV 업로드·증분 upsert
│       ├── company/     # 회사 가입/승인, client_code 발급
│       ├── member/      # 회원가입/로그인(세션), 직원 승인
│       ├── widget/      # 임베드 스크립트 발급
│       ├── config/      # SecurityConfig, OpenSearch/AI서버 설정
│       └── global/      # 공통 예외 처리
├── ai-server/                               # FastAPI 임베딩·LLM 서버
│   ├── main_exaone.py                       # bge-m3 임베딩 + Ollama(EXAONE 3.5) 생성
│   └── main_gemma.py                        # bge-m3 임베딩 + Gemma 3 4B-IT(in-process) 생성
├── data-pipeline/
│   └── crawling/
│       ├── daiso/                           # Selenium 기반 다이소몰 크롤러 (재개 가능)
│       ├── fashion/                         # BeautifulSoup 기반 66girls 크롤러
│       └── common/
└── frontend/                                # 순수 HTML/CSS/JS
    ├── admin/                               # 플랫폼 관리자 콘솔
    ├── company/                             # 테넌트 관리자 콘솔 (업로드/위젯 스크립트/멤버 관리)
    ├── customer/                            # 챗봇 데모 UI
    ├── login/
    └── demo-shop/                           # 다이소몰/66girls 클론 + 위젯 임베드 데모
```

---

## 🌐 주요 API 엔드포인트

| 분류 | 메서드/경로 | 설명 |
|------|------|------|
| 회원 | `POST /api/members/signup`, `/login`, `/logout` | 회원가입/로그인(세션)/로그아웃 |
| 회원 | `PATCH /api/members/password`, `DELETE /api/members/withdraw` | 비밀번호 변경, 회원 탈퇴 |
| 관리자 | `GET /api/admin/companies/pending`, `POST /{id}/approve\|reject` | 회사 가입 승인/반려 |
| 관리자 | `GET/DELETE /api/admin/members`, `/{memberId}` | 전체 회원 조회/삭제 |
| 회사 | `GET /api/company/members/pending`, `POST /{memberId}/approve\|reject` | 소속 직원 승인 |
| 챗봇 | `POST /api/chat` | 질문 → 벡터 검색 → LLM 생성 → 답변 반환 |
| 챗봇 | `GET/DELETE /api/chat-logs`, `/{id}` | 대화 로그 조회/삭제 |
| 상품 | `POST /api/products/preview`, `/confirm` | CSV 미리보기 → 컬럼 매핑 → 확정 업로드 |
| 상품 | `GET/PUT/DELETE /api/product-items` | 상품 아이템 CRUD |
| 상품 | `GET /api/product-items/public/{clientCode}` | 위젯에서 사용하는 공개 상품 조회 |
| 위젯 | `GET /api/widget/script` | 임베드용 `<script>` 태그 발급 |
| AI 서버 | `POST /embed`, `/embed/batch`, `/generate` | 임베딩·배치 임베딩·RAG 답변 생성 |

> 전체 스펙은 서버 실행 후 `/swagger-ui.html`에서 확인할 수 있습니다.

---

## 🗄️ 데이터 모델

| 엔티티 | 설명 |
|------|------|
| `Company` | 쇼핑몰 운영사, `client_code`(가입 시 즉시 발급), 승인 상태(PENDING/APPROVED/REJECTED, 계정 활성화 여부만 제어) |
| `Member` | 회원, 권한(ADMIN/COMPANY_OWNER/EMPLOYEE), 승인 상태 |
| `Product` / `ProductItem` | 업로드 파일 단위 / 개별 상품(soft-delete, `externalProductId` 기반 upsert 매칭) |
| `CompanyCsvMapping` | 회사별로 저장해두는 CSV 컬럼 매핑 (재업로드 시 재사용) |
| `ChatLog` | 회사별 질문/답변/fallback 여부 기록 |

### OpenSearch 인덱스 (`product_items_exaone_test`)

> 인덱스명이 테스트 단계 명칭 그대로 운영에 쓰이고 있음 — 운영용 명칭으로 정리 필요 (아래 "알려진 이슈" 참고)

| 필드 | 타입 | 설명 |
|------|------|------|
| `client_code` | keyword | 테넌트 격리 필터 키 |
| `company_id` | long | 소속 회사 식별자 |
| `product_item_id` | long | 상품 아이템 식별자 (PostgreSQL `ProductItem`과 매핑) |
| `product_name` | text | 상품명 |
| `price` | integer | 가격 |
| `categories` | keyword | 카테고리 |
| `description` | text | 상품 설명 |
| `product_url` | keyword | 상품 상세 URL |
| `chunk_text` | text | "상품명/가격/카테고리/설명"을 합친 임베딩 원문 |
| `chunk_vector` | knn_vector(1024) | bge-m3 임베딩, HNSW/cosine |

---

## 🚀 실행 방법

### 1. 사전 준비
- PostgreSQL, OpenSearch(로컬 9200) 실행
- `backend/src/main/resources/application-local.yaml.example`을 복사해 DB 접속정보 입력
- AI 서버용 GPU 환경 (EXAONE 사용 시 Ollama 실행 + `exaone3.5:7.8b` pull, Gemma 사용 시 HuggingFace 모델 다운로드)

### 2. AI 서버 실행

```bash
cd ai-server
pip install -r requirements_exaone.txt   # 또는 requirements_gemma.txt
uvicorn main_exaone:app --host 0.0.0.0 --port 8000   # 또는 main_gemma:app
```

### 3. 백엔드 실행

```bash
cd backend
./mvnw spring-boot:run
```

- API 문서: `http://localhost:8080/swagger-ui.html`

### 4. 데모 확인
`frontend/demo-shop/daiso.html` 또는 `66girls.html`을 브라우저로 열면, 하단에 임베드된 위젯을 통해 실제 상품 데이터를 근거로 한 챗봇 답변을 확인할 수 있습니다.

### 5. (선택) 크롤러로 데모 데이터 직접 수집

```bash
cd data-pipeline/crawling
pip install -r requirements.txt
python daiso/crawl_daiso.py      # 재개 가능, robots.txt 준수
python fashion/crawl_66girls.py
```

---

## 🖥️ 개발 환경

| 항목 | 버전 / 내용 |
|------|------------|
| Java | 17 |
| Spring Boot | 4.1.0 |
| Python | 3.12 |
| OpenSearch Client | 3.5.0 |
| 임베딩 모델 | BAAI/bge-m3 (1024차원) |
| LLM | EXAONE 3.5 7.8B (Ollama) / Gemma 3 4B-IT (transformers) |
| DB | PostgreSQL |

---

## ✅ 구현 완료 목록

- [x] client_code 기반 멀티테넌트 벡터 검색 격리 (OpenSearch k-NN, HNSW/cosine)
- [x] CSV 상품 데이터 업로드(미리보기/컬럼 매핑/확정) 및 증분 upsert
- [x] 벡터 검색 + LLM 생성 RAG 챗봇 (할루시네이션 가드레일 프롬프트)
- [x] AI 서버 장애·지연 시 Fallback 응답 정책
- [x] 원라인 임베드 위젯 (상품 추천 카드 렌더링 포함)
- [x] 회사 가입 승인 / 직원 승인 2단계 권한 워크플로우
- [x] Ollama(EXAONE 3.5) / transformers(Gemma 3) 이중 LLM 백엔드 구현·비교
- [x] Selenium/BeautifulSoup 기반 다이소몰·66girls 크롤러 (재개 가능, robots.txt 준수)
- [x] 업로드 소요시간 계측을 통한 임베딩 배치 타임아웃 이슈 진단 및 해결 (전체 처리시간 약 52% 단축, 33분 59초 → 16분 13초)
- [x] Toast/Modal 기반 UI 피드백 시스템 도입 (company/admin 콘솔 적용 완료, customer 일부 화면에는 네이티브 alert 잔존 — 아래 "알려진 이슈" 참고)

---

## ⚠️ 알려진 이슈 / 개선 예정

| 이슈 | 상태 | 비고 |
|------|------|------|
| 인증이 세션 기반, JWT 미도입 | 개선 예정 | 다중 서버 확장 시 세션 클러스터링/JWT 전환 검토 |
| `SecurityConfig`가 현재 전체 요청 permitAll | 개선 예정 | 개발 단계 설정, 배포 전 엔드포인트별 인가 규칙 적용 필요 |
| 기본 관리자 계정이 코드에 하드코딩(`AdminInitializer`) | 개선 예정 | 배포 전 환경변수/시드 스크립트로 분리 필요 |
| 테스트 코드 부재 (컨텍스트 로드 테스트만 존재) | 개선 예정 | 서비스 계층 단위 테스트, AI 서버 테스트 추가 검토 |
| CI/CD, Dockerfile 부재 | 개선 예정 | 컨테이너화 및 배포 자동화 검토 중 |
| 크롤러 결과물이 자동 파이프라인 없이 수동 업로드로 연결됨 | 확인 필요 | 크롤링 → 업로드 자동 연동 검토 |
| OpenSearch 인덱스명이 테스트 단계 명칭(`product_items_exaone_test`) 그대로 사용 중 | 개선 예정 | 운영용 인덱스명으로 정리 필요 |
| customer 화면 일부에 네이티브 `alert()` 잔존 (`customer.js:14`) | 개선 예정 | company/admin 콘솔은 Toast/Modal로 전환 완료, customer 쪽 마무리 필요 |

---

## 📚 학습 내용

| 분야 | 핵심 학습 내용 |
|------|------|
| 멀티테넌트 RAG 설계 | 하나의 벡터 인덱스에서 테넌트 격리를 필터 조건으로 구현하는 방법과 그 트레이드오프 |
| 성능 트러블슈팅 | 계측 로그를 근거로 대용량 업로드의 병목 구간(임베딩 배치)을 특정하고, 병렬화로 전체 처리 시간을 약 52% 단축 |
| LLM 서빙 전략 비교 | 외부 프로세스(Ollama) 경유 방식과 in-process(transformers) 방식의 운영 편의성/제어력 트레이드오프 |
| 장애 격리 설계 | 외부 AI 서버 의존성을 가진 기능에서 예외를 그대로 전파하지 않고 Fallback으로 흡수하는 패턴 |
| 크롤링 안정성 | robots.txt 준수, 체크포인트 기반 재개, 드라이버 재시작 주기 설계로 장시간 크롤링의 안정성 확보 |

---

## 👥 팀 구성

> 2인 프로젝트 (Backend/AI 파트, Frontend/Data Pipeline 파트)
