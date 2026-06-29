"""
육육걸즈(66girls.co.kr) 상품 크롤러

전략:
- 카테고리 리스트 페이지(/product/list.html?cate_no=XX)는 완전 정적 HTML이므로
  requests + BeautifulSoup만으로 상품명/가격/짧은 설명/링크를 모두 추출 가능.
- 서브카테고리별로 1페이지(기본 노출 약 30개)만 수집하면 목표(서브카테고리당 30개) 충족.
- Selenium 불필요.

사용법:
    python crawl_66girls.py

출력:
    data/raw/fashion_shop/66girls_products.csv
"""
import os
import sys
import csv
import re
import logging

from bs4 import BeautifulSoup

sys.path.append(os.path.join(os.path.dirname(__file__), ".."))
from common.utils import fetch_html, clean_price, polite_sleep
from fashion.config import (
    BASE_URL,
    CATEGORIES,
    TARGET_PER_SUBCATEGORY,
    OUTPUT_DIR,
    OUTPUT_FILENAME,
    REQUEST_DELAY_SEC,
)

logger = logging.getLogger("widgetrag_crawler")

# 상품 카드 내 링크 패턴: /product/{슬러그}/{상품번호}/category/{cate_no}/display/{순서}/
# display 값도 함께 캡처한다.
#   display=1 -> 메인 상품 리스트 (우리가 원하는 영역)
#   display=2 -> 페이지 상단 "BEST" 추천 영역 (제외 대상)
PRODUCT_LINK_PATTERN = re.compile(r"/product/[^/]+/(\d+)/category/\d+/display/(\d+)/")
MAIN_LIST_DISPLAY_NO = "1"


def build_list_url(cate_no: int, page: int = 1) -> str:
    return f"{BASE_URL}/product/list.html?cate_no={cate_no}&page={page}"


def parse_product_list(html: str, category_main: str, category_sub: str) -> list[dict]:
    """
    카테고리 리스트 페이지 HTML에서 상품 정보를 추출한다.
    리스트 페이지에 이미 상품명/가격/짧은 설명/이미지/링크가 모두 들어있으므로
    상세 페이지 진입 없이 1회 요청으로 충분히 채운다.
    """
    soup = BeautifulSoup(html, "html.parser")
    products = []

    # 카페24 표준 상품 리스트는 li.xans-record- 단위로 한 상품을 감싸는 경우가 많으나
    # 사이트 커스텀 마크업 차이가 있을 수 있어, 상품 상세 링크 패턴으로 직접 탐지한다.
    seen_ids = set()
    for a_tag in soup.find_all("a", href=True):
        href = a_tag["href"]
        match = PRODUCT_LINK_PATTERN.search(href)
        if not match:
            continue

        product_id = match.group(1)
        display_no = match.group(2)

        # 페이지 상단 "BEST" 추천 영역(display=2 등)은 메인 카테고리 리스트가 아니므로 제외.
        # 이 영역의 가격/설명 마크업 구조가 메인 리스트와 달라 파싱이 부정확해지고,
        # 메인 리스트 상품과 중복으로 잡히는 문제도 있었음.
        if display_no != MAIN_LIST_DISPLAY_NO:
            continue

        # 상품명: a 태그의 텍스트 (이미지 링크는 텍스트가 비어있으므로 먼저 걸러낸다)
        # 주의: seen_ids 등록보다 먼저 검사해야 한다.
        # 이미지 링크(텍스트 없음)를 먼저 seen_ids에 등록해버리면,
        # 뒤에 나오는 실제 제목 링크(텍스트 있음)까지 중복으로 오인되어 전부 스킵되는 버그가 있었음.
        name = a_tag.get_text(strip=True)
        if not name:
            continue

        if product_id in seen_ids:
            continue  # 같은 상품을 가리키는 제목 링크가 두 번 나오는 경우 등 중복 제거
        seen_ids.add(product_id)

        # 부모 컨테이너에서 가격/설명 텍스트를 함께 탐색.
        #
        # 실제 사이트 구조는 상품명과 가격이 서로 다른 <li class="name">, <li class="price">
        # 형제 요소로 분리되어 있어, find_parent("li")만으로는 상품명을 감싸는 가장 가까운 li까지만
        # 올라가고 가격 정보는 포함되지 않는 버그가 있었음 (가격 100% 누락의 원인).
        #
        # 상품 카드 전체는 id="anchorBoxId_{product_id}" 속성을 가진 최상위 li로 감싸여 있으므로
        # 이를 우선 탐색하고, 없으면 description 블록, 최후에는 기존 방식으로 폴백한다.
        container = (
            a_tag.find_parent("li", id=re.compile(r"^anchorBoxId_"))
            or a_tag.find_parent("div", class_="description")
            or a_tag.find_parent("li")
            or a_tag.find_parent("div")
            or a_tag.parent
        )
        container_text = container.get_text(" ", strip=True) if container else ""

        # 가격이 여러 개 매칭될 수 있다 (정가, 할인가, 할인가 중복 표시 등).
        # 할인 중인 상품은 보통 [정가, 할인가, 할인가] 순서로 나타나므로
        # 마지막(가장 낮은) 값을 실제 판매가로 사용한다.
        price_matches = re.findall(r"[\d,]+원", container_text)
        price = clean_price(price_matches[-1]) if price_matches else None

        # 상품 짧은 설명: <p class="simple_desc">에 깔끔하게 들어있음.
        # 같은 컨테이너 안에 add_desc(보통 비어있음)도 있어 simple_desc만 명시적으로 선택.
        desc_tag = container.find("p", class_="simple_desc") if container else None
        description = desc_tag.get_text(strip=True) if desc_tag else ""

        full_url = href if href.startswith("http") else BASE_URL + href

        products.append(
            {
                "product_id": product_id,
                "product_name": name,
                "price": price,
                "category_main": category_main,
                "category_sub": category_sub,
                "description": description,
                "url": full_url,
            }
        )

    return products


def crawl_subcategory(category_main: str, category_sub: str, cate_no: int) -> list[dict]:
    logger.info(f"[66girls] 수집 시작: {category_main} > {category_sub} (cate_no={cate_no})")
    url = build_list_url(cate_no, page=1)
    html = fetch_html(url)
    if not html:
        logger.error(f"[66girls] 페이지 요청 실패, 스킵: {category_sub}")
        return []

    if "/category/" not in html:
        logger.warning(
            f"[66girls] '{category_sub}' 응답에 '/category/' 문자열이 전혀 없음 "
            f"(차단 페이지 또는 빈 페이지 의심, 길이={len(html)})"
        )

    products = parse_product_list(html, category_main, category_sub)
    products = products[:TARGET_PER_SUBCATEGORY]
    logger.info(f"[66girls] 수집 완료: {category_sub} -> {len(products)}개")
    return products


FIELDNAMES = [
    "product_id",
    "product_name",
    "price",
    "category_main",
    "category_sub",
    "description",
    "url",
]


def save_csv(products: list[dict], output_path: str) -> None:
    with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(products)


def main():
    all_products: list[dict] = []

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, OUTPUT_FILENAME)

    # 전체 작업 개수 계산 (진행률 표시용)
    total_tasks = sum(
        len(info.get("sub") or {}) if info.get("sub") else 1
        for info in CATEGORIES.values()
    )
    task_idx = 0

    for category_main, info in CATEGORIES.items():
        sub_categories = info.get("sub") or {}

        if sub_categories:
            # 일반적인 경우: 서브카테고리별로 순회하며 각각 30개씩 수집
            for sub_name, cate_no in sub_categories.items():
                task_idx += 1
                logger.info(f"[66girls] 진행률 {task_idx}/{total_tasks}")
                items = crawl_subcategory(category_main, sub_name, cate_no)
                all_products.extend(items)
                polite_sleep(REQUEST_DELAY_SEC)

                # 카테고리 개수가 많아(65개) 중간에 네트워크 문제로 중단될 경우를 대비해
                # 10개 작업마다 지금까지의 결과를 CSV로 중간 저장한다.
                if task_idx % 10 == 0:
                    save_csv(all_products, output_path)
                    logger.info(f"[66girls] 중간 저장 완료 ({task_idx}/{total_tasks}, 누적 {len(all_products)}개)")
        else:
            # 가방/신발처럼 서브카테고리가 없는 메인 카테고리는
            # 메인 카테고리 cate_no에서 그대로 30개를 수집한다.
            # category_sub는 "전체"로 표기해 구분 가능하게 한다.
            task_idx += 1
            logger.info(f"[66girls] 진행률 {task_idx}/{total_tasks}")
            main_cate_no = info["cate_no"]
            items = crawl_subcategory(category_main, "전체", main_cate_no)
            all_products.extend(items)
            polite_sleep(REQUEST_DELAY_SEC)

    save_csv(all_products, output_path)
    logger.info(f"[66girls] 전체 완료: 총 {len(all_products)}개 -> {output_path}")


if __name__ == "__main__":
    main()