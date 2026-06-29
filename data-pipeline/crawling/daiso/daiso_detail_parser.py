"""
다이소몰 상품 상세 페이지 파서

상세 페이지(/pd/pdr/SCR_PDR_0001?pdNo=...)는 SSR이라 requests로 충분.

og:title 포맷: "{상품명} | {브랜드명} | {카테고리} | {가격}원 - 다이소몰"

주의: 처음 확인했던 '대나무 효자손' 샘플은 다이소 자체 PB 상품이라
브랜드명 자리에 "다이소"가 그대로 들어가 있었지만, 입점 브랜드 상품
(예: "어퓨_더퓨어", "VT", "본셉 스킨케어" 등)은 그 자리에 실제
브랜드명이 들어간다. 즉 두 번째 구간은 고정 문자열이 아니라
"임의의 브랜드명"이며, 마지막 "- 다이소몰" 접미사만 고정이다.

meta[property=og:description] -> 상품 설명 전문 (표시사항 등 포함, 매우 길다)
"""

import re
import logging
from typing import Optional

from bs4 import BeautifulSoup

logger = logging.getLogger("widgetrag_crawler")

# og:title 포맷: "상품명 | 브랜드명 | 카테고리 | 1,000원 - 다이소몰"
# 브랜드명 자리는 "다이소"든 입점 브랜드명이든 임의의 텍스트를 허용한다.
OG_TITLE_PATTERN = re.compile(
    r"^(?P<name>.+?)\s*\|\s*(?P<brand>[^|]+?)\s*\|\s*(?P<category>[^|]+?)\s*\|\s*(?P<price>[\d,]+)원\s*-\s*다이소몰\s*$"
)

# 카테고리 구간이 비어있는 경우(예: "... | 김정문알로에 | 5,000원 - 다이소몰")도
# 실제 로그에서 확인됨. 브랜드/카테고리 구분 없이 파이프(|) 2개만 있는 포맷.
OG_TITLE_PATTERN_NO_CATEGORY = re.compile(
    r"^(?P<name>.+?)\s*\|\s*(?P<brand>[^|]+?)\s*\|\s*(?P<price>[\d,]+)원\s*-\s*다이소몰\s*$"
)


def parse_product_detail(html: str, pd_no: str) -> Optional[dict]:
    """
    상품 상세 페이지 HTML에서 상품 정보를 추출한다.
    파싱 실패(필수 필드 누락) 시 None을 반환한다.
    """
    soup = BeautifulSoup(html, "html.parser")

    og_title_tag = soup.find("meta", property="og:title")
    og_desc_tag = soup.find("meta", property="og:description")

    if not og_title_tag or not og_title_tag.get("content"):
        logger.warning(f"[daiso] og:title 없음, 파싱 실패: pdNo={pd_no}")
        return None

    og_title = og_title_tag["content"].strip()

    product_name = None
    category_from_title = ""
    price = None

    m = OG_TITLE_PATTERN.match(og_title)
    if m:
        product_name = m.group("name").strip()
        category_from_title = m.group("category").strip()
        price = int(m.group("price").replace(",", ""))
    else:
        # 파이프(|) 구간이 3개가 아니라 2개뿐인 경우 (카테고리 구간 누락)
        m2 = OG_TITLE_PATTERN_NO_CATEGORY.match(og_title)
        if m2:
            product_name = m2.group("name").strip()
            price = int(m2.group("price").replace(",", ""))
        else:
            logger.warning(f"[daiso] og:title 포맷 불일치, 폴백 시도: pdNo={pd_no} ({og_title})")

    if not product_name:
        # 최종 폴백: <title> 태그 또는 og:title 원문 그대로 첫 파이프 앞부분만 사용
        title_tag = soup.find("title")
        raw_title = title_tag.get_text(strip=True) if title_tag else og_title
        product_name = raw_title.split("|")[0].strip()
        if not price:
            price = _extract_price_fallback(soup)

    description = og_desc_tag["content"].strip() if og_desc_tag and og_desc_tag.get("content") else ""

    if not product_name:
        logger.warning(f"[daiso] 상품명 추출 최종 실패: pdNo={pd_no}")
        return None

    return {
        "product_id": pd_no,
        "product_name": product_name,
        "price": price,
        "category_from_page": category_from_title,
        "description": description,
    }


def _extract_price_fallback(soup: BeautifulSoup) -> Optional[int]:
    """가격 정보를 추출하지 못한 경우 본문 텍스트에서 보조 추출."""
    text = soup.get_text()
    m = re.search(r"([\d,]+)\s*원", text)
    if not m:
        return None
    digits = m.group(1).replace(",", "")
    return int(digits) if digits.isdigit() else None