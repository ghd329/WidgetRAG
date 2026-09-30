# Docker Compose 배포 스크립트

이관 대상 환경의 **실행 형태 2종 중 컨테이너 쪽** 진입물이다.
Shell 설치형은 [`../local/`](../local/) — 진입 방식 · 이관 패키지 · 검증 기준은 두 형태가 같고,
LexAI(`legal-rag-chatbot` `deploy/compose/`)와도 같은 방식이다.

## 새 환경에 올릴 때 — 한 줄

사람이 하는 일은 **VM 생성과 SSH 접속까지**다.

```bash
curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/compose/deploy.sh | bash
```

이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주면 색인 · DB · 업로드 파일까지 복원한다.
Shell 설치형에서 뜬 패키지도 그대로 된다 (형식이 같다 — [`../package.sh`](../package.sh)).

```bash
curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/20260924-1030 bash
```

다른 CSP 의 레지스트리에서 받으려면 접두사만 바꾼다.

```bash
curl -fsSL <위 주소> | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/<프로젝트>/<저장소> IMAGE_TAG=v0.3.0 bash
```

## Shell 설치형과 갈리는 지점

이 스크립트는 **저장소와 독립적으로 동작한다.** 타겟에 git 도 소스도 필요 없다 — 이미지가 곧 산출물이다.

| | Shell 설치형 (`bootstrap.sh`) | Docker Compose (`deploy.sh`) |
| --- | --- | --- |
| 타겟에 놓이는 것 | 저장소 전체 (clone) | 배포 파일 5개 + 이미지 |
| 빌드 | 타겟에서 Maven · pip | 없음 (pull 전용 — `build: !reset null`) |
| GPU | 호스트 드라이버만 | 드라이버 + **nvidia-container-toolkit** |
| 서비스 관리 | `systemctl` (`widgetrag-*`) | `docker compose` |
| 데이터 위치 | 호스트 `~/widgetrag-data` | 네임드 볼륨 `upload-data` · `opensearch-data` |

받는 파일은 이렇다 (배포 디렉토리 `~/widgetrag-deploy`):

```
docker-compose.yml            서비스 정의 (build: 포함 — 아래 오버레이가 지움)
docker-compose.images.yml     build: 제거 + image: 지정 (REGISTRY_PREFIX · IMAGE_TAG)
package.sh                    이관 패키지 수신 · 복원 · 생성 (두 형태 공용)
verify.sh                     합격 기준 검증 (두 형태 공용)
migcheck.py                   이관 동등성 기준선 · 비교 계산 (package.sh · verify.sh 가 부름)
.env                          생성됨 — 관리자 비밀번호 무작위 발급 (600)
snapshots/                    OpenSearch path.repo(/mnt/snapshots) — 색인 스냅샷을 주고받는 곳
```

## 스크립트가 하는 일

1. root 로 실행되면 uid 1000 사용자로, 파이프로 들어오면 디스크 사본으로 다시 실행
2. 기본 도구 (curl · sqlite3 · pigz …)
3. NVIDIA 드라이버 — 없으면 설치 후 **스스로 재부팅하고, 부팅이 끝나면 같은 지점부터 자동으로 이어서 진행**
   (`sudo journalctl -u widgetrag-compose-resume -f`)
4. Docker 엔진 + Compose v2.24+ + nvidia-container-toolkit → **매번 컨테이너를 하나 띄워 GPU 통과 확인**
5. 배포 파일 수신 · `.env` 생성
6. 이미지 pull → `SNAPSHOT_URI` 가 있으면 패키지 수신(체크섬 확인)
7. **앱보다 먼저 복원** — 컨테이너 · 볼륨만 만들고(`up --no-start`) DB · 업로드 파일을 볼륨에 넣은 뒤,
   opensearch 만 올려 색인을 복원하고 나서 전체를 올린다 (backend 는 기동할 때 빈 DB · 빈 색인을 만든다)
8. 서비스 준비 대기 (backend healthy · 모델 적재 · AI 서버 · 프론트)
9. 합격 기준 검증 — Shell 설치형과 같은 판정 · 같은 결과표(`~/widgetrag-run/results.csv`)

여러 번 실행해도 안전하다. DB · 색인이 이미 있으면 복원을 건너뛴다 (덮어쓰려면 `FORCE_RESTORE=1`).

### GPU 통과 확인을 매번 하는 이유

toolkit 이 없거나 설정이 틀리면 **에러 없이 CPU 로 폴백한다.** 컨테이너는 전부 정상으로 보이는데
응답만 느려지고, AI 서버 호출 타임아웃(180초)에 걸려 채팅이 실패하기 시작한다. 증상이 늦게,
엉뚱한 곳에서 드러나므로 기동 전에 실제로 확인한다.

## 환경변수

전부 선택 사항이다.

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `BRANCH` | `feat/20260922-change-sqlite` | 배포 파일을 받을 브랜치 |
| `REPO_RAW` | `https://raw.githubusercontent.com/ghd329/WidgetRAG` | 포크 · 사내 미러 |
| `WORK_DIR` | `~/widgetrag-deploy` | 배포 디렉토리 (사본을 직접 실행하면 그 디렉토리) |
| `REGISTRY_PREFIX` | `yjp8842` | Docker Hub 계정 또는 레지스트리 주소 (ECR · GAR · NCR) |
| `IMAGE_TAG` | `v0.3.0` | **고정 태그를 쓴다** — `latest` 는 어느 이미지가 떴는지 추적이 안 된다 |
| `SNAPSHOT_URI` | — | 이관 패키지 위치 (`s3://` · `gs://` · `https://` · 로컬 경로) |
| `S3_ENDPOINT_URL` | — | S3 호환 스토리지 주소 (NCP 등) |
| `FORCE_RESTORE=1` | — | DB · 색인이 이미 있어도 패키지로 덮어씀 |
| `LLM_TEMPERATURE` · `LLM_SEED` | `0.7` · — | 동등성 비교용 결정적 설정 — 지정하면 `.env` 에 반영 |
| `NO_DRIVER=1` · `NO_START=1` · `SKIP_VERIFY=1` | — | 드라이버 생략 · 준비만 · 검증 생략 |
| `COMPARE=1` · `GOLDEN_CHECK=0` | `0` · `1` | 마지막 검증에서 이관 동등성 대조 · 그중 LLM 골든 대조만 생략 (아래 절) |
| `TARGET_USER` | uid 1000 | root 로 실행될 때 배포할 사용자 |

## 이관 도구 연동

이 한 줄이 CB-Tumblebug 의 `postCommands` 에 그대로 실리는 페이로드다. root 로 실행돼도
uid 1000 사용자로 스스로 전환하므로 배포물이 `/root` 아래에 갇히지 않는다.

## 일상 운영

```bash
cd ~/widgetrag-deploy
sudo docker compose ps                  # 상태
sudo docker compose logs -f backend     # 로그
sudo docker compose down                # 종료 (볼륨은 유지)
bash deploy.sh                          # 재기동 · 갱신
bash package.sh backup                  # 이관 패키지 생성 (UPLOAD_URI=s3://… 면 업로드까지)
```

**`docker compose down -v` 는 쓰지 않는다** — DB · 색인 볼륨까지 지워진다.

## 이관 동등성 테스트

소스에서 패키지를 뜰 때 기준선(데이터 해시 · LLM 골든 답변)을 함께 싣고, 타겟 검증의 7절이 그것과 대조한다.
기본은 꺼져 있다(`COMPARE=0`) — 테스트할 때만 켠다. Shell 설치형과 절차 · 판정이 같다 ([`../local/`](../local/)).

```bash
# [소스] 결정적 설정으로 재기동(.env 반영) → 기준선 + 골든(질문 5개 × 2회)까지 패키지 생성
#   deploy.sh 가 package.sh · verify.sh · migcheck.py 도 새로 받는다. RUNTIME 은 자동 판별에 맡기지 않고 명시한다
cd ~/widgetrag-deploy
LLM_TEMPERATURE=0 LLM_SEED=42 bash deploy.sh
RUNTIME=compose GOLDEN=1 UPLOAD_URI=s3://버킷/widgetrag/$(date +%Y%m%d-%H%M) bash package.sh backup

# [타겟] 같은 결정적 설정으로 복원 · 기동 · 대조 (이미 올라간 환경이면 cd ~/widgetrag-deploy && COMPARE=1 bash verify.sh)
curl -fsSL <deploy 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/<시각> LLM_TEMPERATURE=0 LLM_SEED=42 COMPARE=1 bash
```

- 결과는 `~/widgetrag-run/migration-compare.csv` 에 행 단위로 쌓이고, 증적(원시 응답 · 해시 · 차이)은
  `~/widgetrag-run/migration-<시각>/` — 요약은 그 안의 `summary.txt`.
- **테스트1** (데이터 이관): ① 서비스 · 컨테이너 수와 역할 ② 패키지 파일별 용량 · SHA-256 ③ 데이터 내용 —
  DB 테이블별 행 해시(`chat_log` 는 이관 시점까지, 업로드 경로 접두사는 정규화) · 색인 문서 해시 · 업로드 파일.
- **테스트2** (LLM 완전 일치): 골든 질문마다 **답변 문자열 바이트 단위 동일 + 추천 상품 목록 · 순서 동일 + fallback 아님**.
  전제는 같은 **Ollama 버전 · 모델 digest · GPU** — temperature · seed · 모델이 다르면 FAIL, 환경 차이는 WARN 으로 원인을 짚는다.
- 이 형태의 Ollama 버전은 llm 이미지 태그가 정한다 (`llm-v0.3.0` = 0.34.3). Shell 설치형(A)도 `OLLAMA_VERSION=0.34.3` 으로
  설치해 맞춘다 (`scripts/local/env.sh` 기본값) — A↔B 교차 이관에서 답변이 갈리지 않게 하는 전제다.
  단 `llm/Dockerfile` 은 `ollama/ollama:latest` 를 베이스로 하므로 **llm 이미지를 다시 빌드(새 `IMAGE_TAG`)하면 버전이 바뀔 수 있다** —
  그때는 `sudo docker compose exec llm ollama -v` 로 확인해 A 의 `OLLAMA_VERSION` 을 같은 값으로 맞춘다.
- `GOLDEN_CHECK=0` 이면 테스트2 만 건너뛴다 (SKIP).
- `package.sh` 는 같은 디렉토리의 `migcheck.py`(해시 · 판정 계산)를 쓴다 — `backup` 도 이것이 없으면 멈춘다.
  예전에 배포한 디렉토리라면 `bash deploy.sh` 를 한 번 다시 실행해 함께 받는다.

## 주의

- 같은 VM 에서 Shell 설치형과 **동시에 띄울 수 없다** — 포트(80 · 9200)와 GPU VRAM 이 겹친다. 형태별로 VM 을 따로 둔다.
- 보안 그룹은 22 만 열고 SSH 터널로 접속한다: `ssh -N -L 8081:localhost:80 ubuntu@<IP>` → `http://localhost:8081`
- 외부 포트는 frontend 의 80 뿐이다. caddy 는 이관 검증에 맞춰 뺐다(frontend 의 nginx 가 `/api` 를 프록시).
  HTTPS 가 필요하면 CSP 로드밸런서에서 종료한다.
- 관리자 비밀번호는 패키지에 넣지 않는다 — 이관된 DB 의 계정은 소스의 비밀번호로 로그인한다.
