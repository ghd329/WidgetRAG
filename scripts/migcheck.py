#!/usr/bin/env python3
# ===========================================================
# WidgetRAG 이관 동등성 도구 — package.sh · verify.sh 가 부르는 해시·대조·판정 모음
#
#   소스의 상태(서비스 · 패키지 파일 · DB · 색인 · 업로드 · LLM 응답)를 기준선으로 남기고,
#   타겟에서 같은 방식으로 다시 계산해 한 줄씩(ROW) 대조한다. 표준 라이브러리만 쓴다
#   (python3.8+ — VM 의 시스템 python3 로 바로 돈다).
#
#   사용법 (보통은 package.sh backup/compare 와 verify.sh 가 대신 부른다)
#     python3 migcheck.py inventory <디렉토리> [--exclude 이름]...
#     python3 migcheck.py db-hash <db> --base <접두사> [--chatlog-max-id N] [--immutable] [--exclude-table T]... [--info 파일]
#     python3 migcheck.py rag-hash --index 이름 --pages-dir 디렉토리 [--docs-out 파일]
#     python3 migcheck.py index-meta --index 이름 --mapping 파일 --settings 파일
#     python3 migcheck.py services --runtime native|compose   < 서비스 이름 목록
#     python3 migcheck.py golden-questions [--file 파일]
#     python3 migcheck.py l2-body --l3 파일 --client-code C --question Q
#     python3 migcheck.py golden-build --questions 파일 --client-code C --raw-dir 디렉토리 --meta 파일 --repeat R --out 파일
#     python3 migcheck.py golden-plan --golden 파일
#     python3 migcheck.py golden-compare --golden 파일 --raw-dir 디렉토리 --target-meta 파일 [--diff-dir 디렉토리]
#     python3 migcheck.py compare-tsv --test T --prefix P --source 파일 --target 파일 [--bytes-col K] [--summary-only-if-pass]
#     python3 migcheck.py diff-docs --source 파일 --target 파일 [--limit 20]
#     python3 migcheck.py report --rows 파일 --csv 파일 --timestamp TS --form F --source-form SF --package 이름 --summary 파일
#
#   ROW 형식 (탭 구분 6열): test  item  source  target  result  note
#     result = PASS · FAIL · WARN · SKIP · INFO / 탭·개행은 공백, 빈 값은 "-"
#     source/target 안의 sha256(64자리 16진수)은 앞 12자로 줄여 표시한다 (비교는 전체 값)
#
#   종료코드: 0 정상(비교류는 FAIL 없음) · 1 FAIL 있음/검증 실패 · 2 사용법·내부 오류
# ===========================================================
import argparse
import csv
import difflib
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.parse

RESULTS = ("PASS", "FAIL", "WARN", "SKIP", "INFO")
SHA_RE = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])")
JSON_SEP = (",", ":")

DEFAULT_QUESTIONS = [
    "가장 비싼 상품 추천해줘",
    "3만원 이하 상품 추천해줘",
    "여름에 입기 좋은 옷 추천해줘",
    "친구 생일 선물 추천해줘",
    "지금 인기 있는 상품 추천해줘",
]

# 실행 중인 서비스 이름 → 역할. 두 형태의 이름이 달라도 역할로 대조한다 (교차 이관 A↔B).
SERVICE_ROLES = {
    "native": {
        "opensearch": "search",
        "ollama": "llm",
        "widgetrag-ai": "ai",
        "widgetrag-backend": "backend",
        "widgetrag-frontend": "frontend",
    },
    "compose": {
        "opensearch": "search",
        "llm": "llm",
        "ai-server": "ai",
        "backend": "backend",
        "frontend": "frontend",
    },
}

# 골든 비교의 전제(다르면 FAIL)와 진단(다르면 WARN) 지문 키
PRE_KEYS = ("llm_temperature", "llm_seed", "llm_model", "llm_num_predict")
ENV_KEYS = ("ollama_version", "model_digest", "show_sha256", "gpu", "driver", "embedding_device",
            "python", "torch", "sentence_transformers", "opensearch_version")
# fingerprint 가 값을 못 얻었을 때 쓰는 자리표시 — 전제 비교에서는 "값 없음" 으로 본다
EMPTY_VALUES = ("", "-", "unavailable")

REPORT_HEADER = ["timestamp", "form", "source_form", "package", "test", "item", "source", "target", "result", "note"]


class UsageError(Exception):
    """사용법·입력 오류 — 종료코드 2."""


# ---------- 공통 ----------
def warn(msg):
    sys.stderr.write("migcheck: %s\n" % msg)


def out(line):
    sys.stdout.write(line + "\n")


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_text(s):
    return sha256_bytes(s.encode("utf-8", "surrogateescape"))


def canon(obj, sort_keys=True):
    return json.dumps(obj, sort_keys=sort_keys, ensure_ascii=False, separators=JSON_SEP)


def cell(v):
    s = "" if v is None else str(v)
    s = s.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    return s if s.strip() else "-"


def short_sha(s):
    return SHA_RE.sub(lambda m: m.group(0)[:12], s)


def row(test, item, source, target, result, note):
    """ROW 한 줄 — source/target 의 sha256 은 표시만 12자로 줄인다."""
    if result not in RESULTS:
        raise ValueError("알 수 없는 판정: %s" % result)
    out("\t".join([cell(test), cell(item), short_sha(cell(source)), short_sha(cell(target)),
                   result, cell(note)]))


def read_text(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def read_lines(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return [ln.rstrip("\r\n") for ln in f.read().split("\n")]


def need_file(path, what):
    if not os.path.isfile(path):
        raise UsageError("%s 파일이 없습니다: %s" % (what, path))


def need_dir(path, what):
    if not os.path.isdir(path):
        raise UsageError("%s 디렉토리가 없습니다: %s" % (what, path))


def read_kv(path):
    """key=value 텍스트 (fingerprint · info 형식). 빈 줄·# 줄은 건너뛴다."""
    kv = {}
    for ln in read_lines(path):
        if not ln.strip() or ln.lstrip().startswith("#") or "=" not in ln:
            continue
        k, v = ln.split("=", 1)
        kv[k.strip()] = v.strip()
    return kv


def load_json_file(path, what):
    need_file(path, what)
    try:
        return json.loads(read_text(path))
    except ValueError as e:
        raise UsageError("%s JSON 을 읽지 못했습니다: %s (%s)" % (what, path, e))


def file_sha256(path):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1024 * 1024)
            if not b:
                break
            h.update(b)
            n += len(b)
    return n, h.hexdigest()


def utf8_key(s):
    return str(s).encode("utf-8", "surrogateescape")


# ---------- 1.1 inventory ----------
def cmd_inventory(a):
    need_dir(a.dir, "대상")
    excl = set(a.exclude or [])
    names = []
    for e in os.scandir(a.dir):
        # find -type f 와 같이 일반 파일만 (심볼릭 링크·하위 디렉토리 제외, 비재귀)
        if e.name.startswith(".") or e.name in excl or not e.is_file(follow_symlinks=False):
            continue
        names.append(e.name)
    names.sort(key=os.fsencode)
    for name in names:
        n, h = file_sha256(os.path.join(a.dir, name))
        out("%s\t%d\t%s" % (name, n, h))
    return 0


# ---------- 1.2 db-hash ----------
def qident(name):
    return '"' + name.replace('"', '""') + '"'


def is_internal(name):
    # sqlite_ 로 시작하는 이름은 SQLite 예약(sqlite_sequence · sqlite_autoindex_* 등) — 대소문자 무시
    return name is None or str(name).lower().startswith("sqlite_")


def render_value(v):
    if isinstance(v, (bytes, bytearray, memoryview)):
        return {"$blob": bytes(v).hex()}
    return v


def render_row(vals):
    return json.dumps(vals, ensure_ascii=False, separators=JSON_SEP) + "\n"


def db_header_is_wal(path):
    try:
        with open(path, "rb") as f:
            h = f.read(20)
    except OSError:
        return False
    return len(h) == 20 and h[:16] == b"SQLite format 3\x00" and h[18] == 2 and h[19] == 2


def open_ro(path, immutable):
    """읽기 전용 연결 + 읽기 트랜잭션 시작. 실제로 파일을 읽어 봐야 열기 오류가 드러난다."""
    # ★ mode=ro — 패키지 DB 는 절대 바꾸지 않는다. immutable=1 이면 잠금·-wal/-shm 생성도 없다.
    uri = "file:" + urllib.parse.quote(path) + "?mode=ro" + ("&immutable=1" if immutable else "")
    conn = sqlite3.connect(uri, uri=True, isolation_level=None)
    # 잘못된 UTF-8 텍스트도 원래 바이트 그대로 해시에 들어가게 한다 (디코드 실패로 죽지 않게)
    conn.text_factory = lambda b: b.decode("utf-8", "surrogateescape")
    try:
        # 한 읽기 트랜잭션 — 모든 테이블 · 스키마 · info 가 같은 시점의 스냅샷을 본다
        conn.execute("BEGIN")
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
    except sqlite3.Error:
        conn.close()
        raise
    return conn


def cmd_db_hash(a):
    path = os.path.abspath(a.db)
    need_file(path, "DB")
    base = a.base.rstrip("/")
    prefix = base + "/"
    excl = {"_verify_scratch"} | set(a.exclude_table or [])
    try:
        conn = open_ro(path, a.immutable)
    except sqlite3.OperationalError as e:
        # 일부 SQLite 빌드(예: macOS 기본)는 -wal/-shm 이 없는 WAL DB 를 mode=ro 로 못 연다.
        # -wal 이 없다 = 지금 이 DB 에 쓰는 연결이 없다 → 파일 본체만 읽는 immutable 로 같은 내용을 본다.
        if a.immutable or os.path.exists(path + "-wal"):
            raise
        warn("읽기 전용으로 열지 못해(%s) immutable 로 다시 엽니다 — -wal 이 없어 쓰는 연결이 없는 상태" % e)
        conn = open_ro(path, True)
    results = []
    info = {}
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]
        all_tables = set(tables)
        tables = [t for t in tables if not is_internal(t) and t not in excl]
        for t in tables:
            ti = list(conn.execute("PRAGMA table_info(%s)" % qident(t)))
            cols = sorted(r[1] for r in ti)
            pk = [r[1] for r in sorted((r for r in ti if r[5] > 0), key=lambda r: r[5])]
            order = ", ".join(qident(c) for c in pk) if pk else "rowid"
            where, params = "", ()
            if t == "chat_log" and a.chatlog_max_id is not None:
                where, params = " WHERE id <= ?", (a.chatlog_max_id,)
            sql = "SELECT %s FROM %s%s ORDER BY %s" % (
                ", ".join(qident(c) for c in cols), qident(t), where, order)
            sp = cols.index("storage_path") if t == "product" and "storage_path" in cols else None
            h = hashlib.sha256()
            nrows = nbytes = 0
            for r in conn.execute(sql, params):
                vals = [render_value(v) for v in r]
                if sp is not None:
                    v = vals[sp]
                    # 업로드 경로 접두사는 이관 시 의도적으로 재작성된다 — 정규화해서 비교
                    if isinstance(v, str) and v.startswith(prefix):
                        vals[sp] = "{BASE}" + v[len(base):]
                b = render_row(vals).encode("utf-8", "surrogateescape")
                h.update(b)
                nrows += 1
                nbytes += len(b)
            results.append((t, nrows, nbytes, h.hexdigest()))

        h = hashlib.sha256()
        nobj = nbytes = 0
        for r in conn.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"):
            typ, name, tbl, sql = r
            if is_internal(name) or name in excl or tbl in excl:
                continue
            b = render_row([typ, name, tbl, sql]).encode("utf-8", "surrogateescape")
            h.update(b)
            nobj += 1
            nbytes += len(b)
        results.append(("_schema", nobj, nbytes, h.hexdigest()))

        if a.info:
            prefixed = 0
            if "product" in all_tables:
                pcols = [r[1] for r in conn.execute("PRAGMA table_info(product)")]
                if "storage_path" in pcols:
                    for (v,) in conn.execute("SELECT storage_path FROM product"):
                        if isinstance(v, str) and v.startswith(prefix):
                            prefixed += 1
            total = max_id = 0
            if "chat_log" in all_tables:
                total = conn.execute("SELECT count(*) FROM chat_log").fetchone()[0]
                max_id = conn.execute("SELECT COALESCE(MAX(id), 0) FROM chat_log").fetchone()[0]
            jm = conn.execute("PRAGMA journal_mode").fetchone()[0]
            # immutable 연결은 WAL 파일이어도 delete 로 답한다 — 파일 헤더(18·19바이트 = 2)로 영속 모드를 본다
            if jm != "wal" and db_header_is_wal(path):
                jm = "wal"
            info = [
                ("storage_path_prefixed", prefixed),
                ("chat_log_total", total),
                ("chat_log_max_id", max_id),
                ("page_size", conn.execute("PRAGMA page_size").fetchone()[0]),
                ("page_count", conn.execute("PRAGMA page_count").fetchone()[0]),
                ("freelist_count", conn.execute("PRAGMA freelist_count").fetchone()[0]),
                ("journal_mode", jm),
            ]
        conn.execute("COMMIT")
    finally:
        conn.close()

    if a.info:
        with open(a.info, "w", encoding="utf-8", newline="") as f:
            for k, v in info:
                f.write("%s=%s\n" % (k, v))
    for t, n, b, h in sorted(results, key=lambda x: x[0]):
        out("%s\t%d\t%d\t%s" % (t, n, b, h))
    return 0


# ---------- 1.3 rag-hash ----------
def cmd_rag_hash(a):
    need_dir(a.pages_dir, "페이지")
    pages = sorted(n for n in os.listdir(a.pages_dir) if n.startswith("page-") and n.endswith(".json"))
    if not pages:
        raise UsageError("page-*.json 이 없습니다: %s" % a.pages_dir)
    docs = {}
    expect = None
    for i, name in enumerate(pages):
        resp = load_json_file(os.path.join(a.pages_dir, name), "검색 응답")
        if not isinstance(resp, dict) or "error" in resp or not isinstance(resp.get("hits"), dict):
            raise UsageError("검색 응답이 아닙니다: %s" % name)
        hits = resp["hits"]
        if i == 0:
            tot = hits.get("total")
            if isinstance(tot, dict) and "value" in tot:
                expect = tot["value"]
            elif isinstance(tot, int) and not isinstance(tot, bool):
                expect = tot
        for hit in hits.get("hits") or []:
            did = hit.get("_id")
            if did in docs:
                raise UsageError("_id 중복: %s (%s)" % (did, name))
            docs[did] = hit.get("_source")
    if expect is not None and expect != len(docs):
        raise UsageError("hits.total(%s) 과 수집 건수(%d) 가 다릅니다 — 스크롤이 도중에 끊겼거나 색인이 바뀌었습니다"
                         % (expect, len(docs)))

    h_full, h_novec = hashlib.sha256(), hashlib.sha256()
    nbytes = 0
    lines = []
    for did in sorted(docs, key=utf8_key):
        src = docs[did]
        c = canon({"_id": did, "_source": src})
        b = (c + "\n").encode("utf-8", "surrogateescape")
        h_full.update(b)
        nbytes += len(b)
        nov = {k: v for k, v in src.items() if k != "chunk_vector"} if isinstance(src, dict) else src
        h_novec.update((canon({"_id": did, "_source": nov}) + "\n").encode("utf-8", "surrogateescape"))
        if a.docs_out:
            lines.append("%s\t%s\t%s\n" % (cell(a.index), cell(did), sha256_text(c)))
    if a.docs_out:
        with open(a.docs_out, "a", encoding="utf-8", newline="") as f:
            f.writelines(lines)
    out("%s\t%d\t%d\t%s\t%s" % (a.index, len(docs), nbytes, h_full.hexdigest(), h_novec.hexdigest()))
    return 0


# ---------- 1.4 index-meta ----------
def index_body(resp, idx, what):
    if isinstance(resp, dict) and idx in resp:
        return resp[idx]
    # 별칭으로 불렀으면 응답 키가 실제 인덱스 이름이다 — 하나뿐이면 그것을 쓴다
    if isinstance(resp, dict) and len(resp) == 1 and "error" not in resp:
        return next(iter(resp.values()))
    raise UsageError("%s 응답에 인덱스 %s 가 없습니다" % (what, idx))


def cmd_index_meta(a):
    mp = index_body(load_json_file(a.mapping, "mapping"), a.index, "mapping")
    st = index_body(load_json_file(a.settings, "settings"), a.index, "settings")
    try:
        mappings = mp["mappings"]
        sidx = st["settings"]["index"]
    except (KeyError, TypeError):
        raise UsageError("mapping/settings 응답 형식이 아닙니다: %s" % a.index)
    settings = {k: sidx.get(k) for k in ("knn", "number_of_shards", "number_of_replicas")}
    out("%s#mapping\t-\t-\t%s\t-" % (a.index, sha256_text(canon(mappings))))
    out("%s#settings\t-\t-\t%s\t-" % (a.index, sha256_text(canon(settings))))
    return 0


# ---------- 1.5 services ----------
def cmd_services(a):
    roles = SERVICE_ROLES[a.runtime]
    seen = {}
    for ln in sys.stdin.read().split("\n"):
        name = ln.strip()
        if name.endswith(".service"):
            name = name[:-len(".service")]
        if not name or name in seen:
            continue
        # 모르는 이름은 역할 자체를 extra:<이름> 으로 둔다 — 서로 다른 여분 서비스가 같은 역할로 묶이지 않게
        seen[name] = roles.get(name, "extra:" + name)
    pairs = sorted(((r, n) for n, r in seen.items()), key=lambda p: (utf8_key(p[0]), utf8_key(p[1])))
    out("SERVICE_COUNT=%d" % len(pairs))
    out("SERVICES=" + ",".join("%s:%s" % p for p in pairs))
    return 0


# ---------- 1.6 golden-questions ----------
def norm_question(q):
    # 탭·개행이 섞이면 golden-plan(TSV) 한 줄이 깨진다 — 공백으로 바꾼다
    q = unicodedata.normalize("NFC", q.strip())
    return q.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def cmd_golden_questions(a):
    if a.file:
        need_file(a.file, "질문")
        qs = [ln for ln in read_lines(a.file) if ln.strip() and not ln.strip().startswith("#")]
    else:
        qs = DEFAULT_QUESTIONS
    qs = [norm_question(q) for q in qs]
    if not qs:
        raise UsageError("질문이 없습니다: %s" % a.file)
    for q in qs:
        out(q)
    return 0


# ---------- 1.7 l2-body ----------
def build_l2_body(products, client_code, question):
    """recommendedProducts → ai-server /generate 본문 (백엔드 AiServerClient 와 같은 3개 필드 · 같은 순서)."""
    if not isinstance(products, list) or not products:
        return None
    items = []
    for p in products:
        if not isinstance(p, dict):
            return None
        items.append({"productName": p.get("productName"), "price": p.get("price"),
                      "category": p.get("category")})
    return {"clientCode": client_code, "question": question, "products": items}


def cmd_l2_body(a):
    try:
        l3 = json.loads(read_text(a.l3))
    except (OSError, ValueError):
        return 1
    body = build_l2_body(l3.get("recommendedProducts") if isinstance(l3, dict) else None,
                         a.client_code, a.question)
    if body is None:
        return 1
    out(json.dumps(body, ensure_ascii=False, separators=JSON_SEP))
    return 0


# ---------- 1.8 응답 유효성 ----------
class Resp(object):
    """원시 응답 한 쌍(<prefix>.json · <prefix>.code)."""

    def __init__(self, prefix):
        self.prefix = prefix
        self.present = os.path.exists(prefix + ".json") or os.path.exists(prefix + ".code")
        try:
            code = read_text(prefix + ".code").strip()
        except (OSError, ValueError):
            code = ""
        self.code = code or "000"
        self.parsed = False
        self.body = None
        try:
            self.body = json.loads(read_text(prefix + ".json"))
            self.parsed = True
        except (OSError, ValueError):
            pass

    def get(self, key):
        return self.body.get(key) if isinstance(self.body, dict) else None

    @property
    def answer(self):
        v = self.get("answer")
        return v if isinstance(v, str) else None

    @property
    def products(self):
        return self.get("recommendedProducts")


def nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def l3_state(r):
    """('ok'|'fallback'|'invalid', 사유)."""
    if r.code != "200":
        return "invalid", "HTTP %s" % r.code
    if not r.parsed or not isinstance(r.body, dict):
        return "invalid", "JSON 파싱 실패"
    fb = r.body.get("isFallback")
    if fb is True:
        return "fallback", "fallback 응답"
    if fb is not False:
        return "invalid", "isFallback 이 false 가 아님(%s)" % json.dumps(fb)
    if not nonempty_str(r.body.get("answer")):
        return "invalid", "빈 답변"
    prods = r.body.get("recommendedProducts")
    if not isinstance(prods, list) or not prods:
        return "invalid", "추천 상품 없음"
    for p in prods:
        if not isinstance(p, dict) or p.get("productItemId") is None:
            return "invalid", "productItemId 가 null"
    return "ok", "-"


def l2_state(r):
    if r.code != "200":
        return False, "HTTP %s" % r.code
    if not r.parsed or not isinstance(r.body, dict):
        return False, "JSON 파싱 실패"
    if not nonempty_str(r.body.get("answer")):
        return False, "빈 답변"
    return True, "-"


def products_canon(products):
    return canon(products)


def answer_sha(ans):
    return sha256_text(ans) if isinstance(ans, str) else None


def first_diff(a, b):
    a, b = a or "", b or ""
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


# ---------- 1.9 golden-build ----------
def cmd_golden_build(a):
    need_file(a.questions, "질문")
    need_file(a.meta, "지문(meta)")
    need_dir(a.raw_dir, "원시 응답")
    if a.repeat < 1:
        raise UsageError("--repeat 는 1 이상이어야 합니다")
    questions = [ln for ln in read_lines(a.questions) if ln.strip()]
    meta_in = read_kv(a.meta)
    R = a.repeat

    collected = []
    for i, q in enumerate(questions, 1):
        qid = "q%02d" % i
        runs = []
        for r in range(1, R + 1):
            base = os.path.join(a.raw_dir, "r%d-%s" % (r, qid))
            runs.append((Resp(base + "-l3"), Resp(base + "-l2")))
        # 원시 파일이 한 회차라도 아예 없으면 수집되지 않은 문항 — 무효가 아니라 불완전으로 본다
        if not all(l3.present for l3, _ in runs):
            continue
        collected.append((qid, q, runs))

    status = None
    for qid, _, runs in collected:
        for l3, _ in runs:
            st, _why = l3_state(l3)
            if st != "ok":
                status = "failed:%s:%s" % (st, qid)
                break
        if status:
            break
    if not status:
        for qid, _, runs in collected:
            if not all(l2_state(l2)[0] and l2.answer == l3.answer for l3, l2 in runs):
                status = "failed:l2-mismatch:%s" % qid
                break
    items = []
    for qid, q, runs in collected:
        sig = [(l3.answer, products_canon(l3.products), l2.answer) for l3, l2 in runs]
        stable = all(s == sig[0] for s in sig)
        l3, l2 = runs[0]
        variants = []
        if not stable:
            for r, (v3, v2) in enumerate(runs, 1):
                variants.append({"r": r, "answer": v3.answer, "answer_sha256": answer_sha(v3.answer),
                                 "recommendedProducts": v3.products,
                                 "products_sha256": sha256_text(products_canon(v3.products)),
                                 "l2_answer": v2.answer})
        items.append({
            "id": qid, "clientCode": a.client_code, "question": q,
            "answer": l3.answer, "answer_sha256": answer_sha(l3.answer),
            "recommendedProducts": l3.products,
            "products_sha256": sha256_text(products_canon(l3.products)),
            "isFallback": l3.get("isFallback"), "l2_answer": l2.answer,
            "stable": stable, "variants": variants,
        })
    if not status:
        for it in items:
            if not it["stable"]:
                status = "failed:unstable:%s" % it["id"]
                break
    # 질문이 하나도 없으면 기준으로 쓸 수 없다 — 불완전으로 본다
    if not status and (len(collected) != len(questions) or not questions):
        status = "failed:incomplete"
    status = status or "ok"

    meta = dict(meta_in)
    meta.update({"client_code": a.client_code, "questions": len(questions), "repeat": R, "status": status})
    golden = {"format": 1, "meta": meta, "items": items}
    with open(a.out, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(golden, ensure_ascii=False, indent=1) + "\n")
    out("GOLDEN_STATUS=%s" % status)
    out("GOLDEN_ITEMS=%d" % len(items))
    return 0 if status == "ok" else 1


# ---------- 1.10 golden-plan ----------
def load_golden(path):
    g = load_json_file(path, "골든")
    if not isinstance(g, dict) or not isinstance(g.get("items"), list) or not isinstance(g.get("meta"), dict):
        raise UsageError("골든 형식이 아닙니다: %s" % path)
    return g


def cmd_golden_plan(a):
    g = load_golden(a.golden)
    for it in g["items"]:
        cc = it.get("clientCode") or g["meta"].get("client_code")
        q = it.get("question")
        body = build_l2_body(it.get("recommendedProducts"), cc, q)
        out("\t".join([cell(it.get("id")), cell(cc), cell(q),
                       json.dumps(body, ensure_ascii=False, separators=JSON_SEP) if body else "-"]))
    return 0


# ---------- 1.11 golden-compare ----------
def meta_val(m, k):
    v = m.get(k)
    return "" if v is None else str(v).strip()


def ap_label(ans, products):
    a_ = answer_sha(ans)
    return "a:%s p:%s" % (a_[:12] if a_ else "-", sha256_text(products_canon(products))[:12])


def write_diff(path, qid, question, note, src_ans, tgt_ans, l2_ans, off, src_prods, tgt_prods):
    def block(title, text):
        return "[%s]\n%s\n\n" % (title, text if text is not None else "(없음)")

    body = "# %s — %s\n질문: %s\n첫 차이: %s\n\n" % (qid, note, question, "-" if off is None else "%d자" % off)
    body += block("소스 답변", src_ans)
    body += block("타겟 답변", tgt_ans)
    body += block("타겟 L2 답변 (소스 추천 상품으로 생성)", l2_ans)
    # 끝 줄에도 개행을 붙여야 -/+ 줄이 한 줄로 붙지 않는다
    ud = "".join(difflib.unified_diff(((src_ans or "") + "\n").splitlines(True),
                                      ((tgt_ans or "") + "\n").splitlines(True), "source", "target"))
    body += block("답변 차이 (source → target)", ud.rstrip("\n") or "(같음)")
    body += block("소스 추천 상품", json.dumps(src_prods, ensure_ascii=False, indent=1))
    body += block("타겟 추천 상품", json.dumps(tgt_prods, ensure_ascii=False, indent=1))
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(body)


def cmd_golden_compare(a):
    g = load_golden(a.golden)
    need_dir(a.raw_dir, "원시 응답")
    sm = g["meta"]
    if os.path.isfile(a.target_meta):
        tm = read_kv(a.target_meta)
    else:
        # 지문이 없으면 전제·진단이 전부 "값 없음" 으로 드러난다 — 여기서 멈추지 않고 ROW 로 남긴다
        warn("타겟 지문 파일이 없습니다: %s" % a.target_meta)
        tm = {}
    if a.diff_dir:
        os.makedirs(a.diff_dir, exist_ok=True)
    fails = 0

    def emit(item, s, t, res, note):
        nonlocal fails
        if res == "FAIL":
            fails += 1
        row("T2", item, s, t, res, note)

    st = meta_val(sm, "status")
    emit("golden:status", st, "-", "PASS" if st == "ok" else "FAIL",
         "-" if st == "ok" else "소스 골든 불완전(%s) — 이관과 무관" % (st or "-"))

    items = g["items"]
    nq = sm.get("questions")
    ok_items = isinstance(nq, int) and not isinstance(nq, bool) and len(items) == nq and len(items) >= 1
    emit("golden:items", "%d개" % len(items), "%s문항" % (nq if nq is not None else "-"),
         "PASS" if ok_items else "FAIL", "-" if ok_items else "골든 항목 수가 질문 수와 다르거나 없음")

    for k in PRE_KEYS:
        s, t = meta_val(sm, k), meta_val(tm, k)
        if s in EMPTY_VALUES or t in EMPTY_VALUES:
            emit("pre:" + k, s, t, "FAIL", "값 없음 — 전제 확인 불가")
        elif s == t:
            emit("pre:" + k, s, t, "PASS", "-")
        else:
            emit("pre:" + k, s, t, "FAIL", "전제 불일치 — 같은 값으로 AI 서버를 기동해야 응답 완전 일치 비교가 성립")
    for k in ENV_KEYS:
        s, t = meta_val(sm, k), meta_val(tm, k)
        if s in EMPTY_VALUES or t in EMPTY_VALUES:
            emit("env:" + k, s, t, "WARN", "값 없음(수집 실패)")
        elif s == t:
            emit("env:" + k, s, t, "PASS", "-")
        else:
            emit("env:" + k, s, t, "WARN", "환경 차이 — 응답이 다르면 먼저 확인")
    s, t = meta_val(sm, "ollama_processor"), meta_val(tm, "ollama_processor")
    gpu_ok = "100% GPU" in t
    emit("env:ollama_processor", s, t, "PASS" if gpu_ok else "WARN",
         "-" if gpu_ok else "타겟 모델이 GPU 에 전부 올라가지 않음")

    for idx, it in enumerate(items, 1):
        qid = str(it.get("id") or "q%02d" % idx)
        src_ans = it.get("answer") if isinstance(it.get("answer"), str) else None
        src_prods = it.get("recommendedProducts")
        base = os.path.join(a.raw_dir, "t-%s" % qid)
        l3, l2 = Resp(base + "-l3"), Resp(base + "-l2")
        l3s, l3why = l3_state(l3)
        l2ok, l2why = l2_state(l2)
        tgt_ans, tgt_prods = l3.answer, l3.products
        same_prods = l3.parsed and products_canon(tgt_prods) == products_canon(src_prods)
        same_ans = src_ans is not None and tgt_ans == src_ans
        l2_same = l2ok and src_ans is not None and l2.answer == src_ans
        off = first_diff(src_ans, tgt_ans)
        src_label = ap_label(src_ans, src_prods)
        tgt_label = ap_label(tgt_ans, tgt_prods) if l3.parsed else "a:- p:-"

        if it.get("stable") is False:
            note = "소스 자체 재현 불가 — 이관과 무관"
        elif it.get("isFallback") is not False or not nonempty_str(src_ans):
            note = "소스 골든 항목 비정상(fallback·빈 답변) — 이관과 무관"
        elif l3s != "ok":
            note = "타겟 응답 비정상 (fallback·오류·빈 답변) · %s" % l3why
        elif same_prods and same_ans:
            note = None
        else:
            if not same_prods and l2_same:
                note = "검색 계층 불일치 (생성 동일)"
            elif same_prods and l2_same:
                note = "재현성 문제 (캐시·동시 요청)"
            elif same_prods:
                note = "생성 계층 불일치 (Ollama·모델·GPU 확인)"
            else:
                note = "검색·생성 모두 불일치"
            if off is not None:
                note += " · 첫 차이 %d자" % off
            if not l2ok:
                # L2 가 실패했으면 "생성 다름" 은 추정일 뿐이다 — 근거를 밝혀 둔다
                note += " · L2 응답 비정상(%s)" % l2why

        if note is None:
            emit(qid, src_label, tgt_label, "PASS", "답변·추천 상품 완전 일치")
            continue
        emit(qid, src_label, tgt_label, "FAIL", note)
        if a.diff_dir:
            write_diff(os.path.join(a.diff_dir, "%s.diff" % qid), qid, it.get("question"), note,
                       src_ans, tgt_ans, l2.answer, off, src_prods, tgt_prods if l3.parsed else None)
    return 1 if fails else 0


# ---------- 1.12 compare-tsv ----------
def read_tsv(path):
    need_file(path, "TSV")
    rows = {}
    order = []
    n = 0
    for ln in read_lines(path):
        if not ln.strip():
            continue
        n += 1
        f = ln.split("\t")
        if f[0] not in rows:
            order.append(f[0])
        rows[f[0]] = f
    return rows, order, n


def col_sum(rows, k):
    s = 0
    for f in rows.values():
        if len(f) >= k:
            try:
                s += int(f[k - 1].strip())
            except ValueError:
                pass
    return s


def cmd_compare_tsv(a):
    src, sorder, sn = read_tsv(a.source)
    tgt, torder, tn = read_tsv(a.target)
    keys = sorted(set(sorder) | set(torder), key=utf8_key)
    out_rows = []
    ok = 0
    for k in keys:
        sv = ":".join(src[k][1:]) if k in src else None
        tv = ":".join(tgt[k][1:]) if k in tgt else None
        if sv is None:
            res, note = "FAIL", "소스에 없음"
        elif tv is None:
            res, note = "FAIL", "타겟에 없음"
        elif sv == tv:
            res, note = "PASS", "일치"
            ok += 1
        else:
            res, note = "FAIL", "값 다름"
        out_rows.append((a.prefix + k, sv, tv, res, note))
    all_pass = ok == len(keys)

    def label(rows, n):
        s = "%d개" % n
        if a.bytes_col:
            s += " · %d bytes" % col_sum(rows, a.bytes_col)
        return s

    if not (a.summary_only_if_pass and all_pass):
        for r in out_rows:
            row(a.test, *r)
    row(a.test, a.prefix + "summary", label(src, sn), label(tgt, tn), "PASS" if all_pass else "FAIL",
        "일치 %d/%d" % (ok, len(keys)))
    return 0 if all_pass else 1


# ---------- 1.13 diff-docs ----------
def read_docs(path):
    need_file(path, "문서 목록")
    idx = {}
    for ln in read_lines(path):
        if not ln.strip():
            continue
        f = ln.split("\t")
        if len(f) < 3:
            continue
        idx.setdefault(f[0], {})[f[1]] = f[2]
    return idx


def cmd_diff_docs(a):
    src, tgt = read_docs(a.source), read_docs(a.target)
    fails = 0
    for name in sorted(set(src) | set(tgt), key=utf8_key):
        s, t = src.get(name, {}), tgt.get(name, {})
        diff = sorted((i for i in set(s) | set(t) if s.get(i) != t.get(i)), key=utf8_key)
        shown = ",".join(diff[:a.limit]) + (",…" if len(diff) > a.limit else "")
        note = "다른 문서 %d건" % len(diff) + (": " + shown if diff else "")
        res = "FAIL" if diff else "PASS"
        fails += res == "FAIL"
        row("T1-3", "rag-docs:" + name, "%d건" % len(s), "%d건" % len(t), res, note)
    return 1 if fails else 0


# ---------- 1.14 report ----------
def read_rows(path):
    need_file(path, "ROW")
    rows = []
    for ln in read_lines(path):
        if not ln.strip():
            continue
        f = ln.split("\t")
        if len(f) < 5 or f[4] not in RESULTS:
            warn("ROW 형식이 아닌 줄을 건너뜁니다: %s" % ln[:80])
            continue
        if len(f) > 6:
            f = f[:5] + [" ".join(f[5:])]
        f += ["-"] * (6 - len(f))
        rows.append(f)
    return rows


def verdict(rows, test):
    rs = [r[4] for r in rows if r[0] == test]
    if "FAIL" in rs:
        return "FAIL"
    if "PASS" not in rs:
        return "미수행"
    return "PASS"


def append_csv(path, meta, rows):
    header = ",".join(REPORT_HEADER)
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
            first = f.readline().rstrip("\r\n")
        if first != header:
            # 열 구성이 바뀐 옛 파일은 지우지 않고 비켜둔다 (verify.sh results.csv 와 같은 규칙)
            stem = path[:-4] if path.endswith(".csv") else path
            dst = "%s-%s.csv" % (stem, time.strftime("%Y%m%d-%H%M%S"))
            n = 1
            while os.path.exists(dst):
                dst = "%s-%s-%d.csv" % (stem, time.strftime("%Y%m%d-%H%M%S"), n)
                n += 1
            os.rename(path, dst)
            warn("열 구성이 다른 기존 파일을 비켜뒀습니다: %s" % dst)
    new = not (os.path.isfile(path) and os.path.getsize(path) > 0)
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "a" if not new else "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(REPORT_HEADER)
        for r in rows:
            w.writerow(meta + r)


def cmd_report(a):
    rows = read_rows(a.rows)
    append_csv(a.csv, [a.timestamp, a.form, a.source_form, a.package], rows)
    tests = ("T1-1", "T1-2", "T1-3", "T2")
    v = {t: verdict(rows, t) for t in tests}
    t1 = [v["T1-1"], v["T1-2"], v["T1-3"]]
    test1 = "FAIL" if "FAIL" in t1 else ("미수행" if "미수행" in t1 else "PASS")
    test2 = v["T2"]
    first = "이관 동등성: 테스트1 %s · 테스트2 %s" % (test1, test2)

    desc = {"T1-1": "서비스 수·역할", "T1-2": "패키지 파일(체크섬·목록)",
            "T1-3": "데이터 내용(DB·RAG·업로드)", "T2": "LLM 응답 완전 일치(골든)"}
    lines = [first,
             "일시 %s · 타겟 %s · 소스 %s · 패키지 %s" % (a.timestamp, a.form, a.source_form, a.package),
             "",
             "%-6s %-6s %5s %5s %5s %5s %5s  %s" % ("test", "판정", "PASS", "FAIL", "WARN", "SKIP", "INFO", "항목")]
    for t in tests:
        cnt = [sum(1 for r in rows if r[0] == t and r[4] == res) for res in RESULTS]
        lines.append("%-6s %-6s %5d %5d %5d %5d %5d  %s" % ((t, v[t]) + tuple(cnt) + (desc[t],)))
    bad = [r for r in rows if r[4] in ("FAIL", "WARN")]
    lines += ["", "FAIL·WARN %d건" % len(bad)]
    if bad:
        for r in bad:
            lines.append("  %s [%s] %s — %s → %s%s" % (r[4], r[0], r[1], r[2], r[3],
                                                      "" if r[5] == "-" else " (%s)" % r[5]))
    else:
        lines.append("  (없음)")
    with open(a.summary, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(lines) + "\n")
    out(first)
    return 0


# ---------- 진입 ----------
class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("migcheck: 사용법 오류: %s\n" % message)
        sys.exit(2)


def build_parser():
    p = Parser(prog="migcheck.py", description="WidgetRAG 이관 동등성 도구")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    sub.required = True

    s = sub.add_parser("inventory", help="디렉토리 파일 목록(이름·바이트·sha256)")
    s.add_argument("dir")
    s.add_argument("--exclude", action="append", default=[])
    s.set_defaults(func=cmd_inventory)

    s = sub.add_parser("db-hash", help="SQLite 논리 해시 (테이블별)")
    s.add_argument("db")
    s.add_argument("--base", required=True)
    s.add_argument("--chatlog-max-id", type=int)
    s.add_argument("--immutable", action="store_true")
    s.add_argument("--exclude-table", action="append", default=[])
    s.add_argument("--info")
    s.set_defaults(func=cmd_db_hash)

    s = sub.add_parser("rag-hash", help="색인 문서 해시 (스크롤 덤프에서)")
    s.add_argument("--index", required=True)
    s.add_argument("--pages-dir", required=True)
    s.add_argument("--docs-out")
    s.set_defaults(func=cmd_rag_hash)

    s = sub.add_parser("index-meta", help="색인 mapping·settings 해시")
    s.add_argument("--index", required=True)
    s.add_argument("--mapping", required=True)
    s.add_argument("--settings", required=True)
    s.set_defaults(func=cmd_index_meta)

    s = sub.add_parser("services", help="실행 중 서비스 → 역할 (stdin)")
    s.add_argument("--runtime", required=True, choices=sorted(SERVICE_ROLES))
    s.set_defaults(func=cmd_services)

    s = sub.add_parser("golden-questions", help="골든 질문 목록")
    s.add_argument("--file")
    s.set_defaults(func=cmd_golden_questions)

    s = sub.add_parser("l2-body", help="L3 응답 → /generate 본문")
    s.add_argument("--l3", required=True)
    s.add_argument("--client-code", required=True)
    s.add_argument("--question", required=True)
    s.set_defaults(func=cmd_l2_body)

    s = sub.add_parser("golden-build", help="소스 원시 응답 → golden.json")
    s.add_argument("--questions", required=True)
    s.add_argument("--client-code", required=True)
    s.add_argument("--raw-dir", required=True)
    s.add_argument("--meta", required=True)
    s.add_argument("--repeat", required=True, type=int)
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_golden_build)

    s = sub.add_parser("golden-plan", help="골든 → 타겟 요청 계획")
    s.add_argument("--golden", required=True)
    s.set_defaults(func=cmd_golden_plan)

    s = sub.add_parser("golden-compare", help="골든 ↔ 타겟 응답 대조 (ROW)")
    s.add_argument("--golden", required=True)
    s.add_argument("--raw-dir", required=True)
    s.add_argument("--target-meta", required=True)
    s.add_argument("--diff-dir")
    s.set_defaults(func=cmd_golden_compare)

    s = sub.add_parser("compare-tsv", help="두 TSV 를 첫 열로 대조 (ROW)")
    s.add_argument("--test", required=True)
    s.add_argument("--prefix", required=True)
    s.add_argument("--source", required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--bytes-col", type=int)
    s.add_argument("--summary-only-if-pass", action="store_true")
    s.set_defaults(func=cmd_compare_tsv)

    s = sub.add_parser("diff-docs", help="문서별 해시 차이 (ROW)")
    s.add_argument("--source", required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--limit", type=int, default=20)
    s.set_defaults(func=cmd_diff_docs)

    s = sub.add_parser("report", help="ROW → CSV 누적 · 요약")
    s.add_argument("--rows", required=True)
    s.add_argument("--csv", required=True)
    s.add_argument("--timestamp", required=True)
    s.add_argument("--form", required=True)
    s.add_argument("--source-form", required=True)
    s.add_argument("--package", required=True)
    s.add_argument("--summary", required=True)
    s.set_defaults(func=cmd_report)
    return p


def main(argv=None):
    # 로캘이 C/POSIX 인 VM 에서도 한국어·UTF-8 이 깨지지 않게, 개행은 항상 LF
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="surrogateescape", newline="\n")
        except (AttributeError, ValueError):
            pass
    try:
        sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    a = build_parser().parse_args(argv)
    try:
        rc = a.func(a)
        sys.stdout.flush()
        return rc
    except UsageError as e:
        warn(str(e))
        return 2
    except BrokenPipeError:
        return 2
    except Exception as e:  # 내부 오류는 1(FAIL)과 구분되게 2
        warn("내부 오류: %s: %s" % (type(e).__name__, e))
        return 2


if __name__ == "__main__":
    sys.exit(main())
