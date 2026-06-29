"""
다이소몰(daisomall.co.kr) 상품 크롤러

흐름:
  1. CATEGORIES를 순회하며 leaf(서브의서브) 카테고리마다:
     a. Selenium으로 카테고리 목록 페이지를 열어 pdNo 목록 추출
     b. 각 pdNo에 대해 requests로 상세 페이지를 받아 파싱
  2. 결과를 CSV로 저장 (10개 leaf 카테고리마다 중간 저장)

실행 (data-pipeline/ 디렉토리에서):
    python -m crawling.daiso.crawl_daiso

이어하기(resume):
- 완료된 leaf는 진행 로그 파일(daiso_progress.json)에 기록되고,
  재실행 시 이미 완료된 leaf는 자동으로 스킵된다.
- "상품 0개"로 끝난 leaf도 완료로 기록한다 (CSV에는 행이 안 남지만
  다시 시도할 필요는 없는 케이스이므로 - 사이트에 실제로 상품이 없는 경우).
- 처음부터 다시 돌리려면 daiso_progress.json과 daiso_products.csv를
  둘 다 지우고 실행할 것.

주의:
- robots.txt Crawl-delay: 30을 존중하여 카테고리 목록 페이지 요청 간격을 둔다.
- Selenium 셀렉터(daiso_selenium.py의 "a[href*='pdNo=']")는 최초 실행 시
  실제 동작을 반드시 확인할 것. 사이트 구조가 다르면 셀렉터 조정이 필요하다.
- "일회용패치"처럼 같은 이름의 leaf가 다른 서브카테고리에 중복 존재할 수 있으므로
  CSV에는 category_sub(상위 서브카테고리명)을 함께 남겨 구분 가능하게 한다.

[패치 내역]
- driver.get()이 WebDriver 프로토콜 레벨에서 무한 대기(120s read timeout)에
  빠져 전체 크롤링이 죽는 문제 대응:
  1) leaf 단위로 SeleniumGetTimeout 발생 시 드라이버를 재시작하고 1회 재시도.
  2) 재시도도 실패하면 해당 leaf는 완료 처리하지 않고 스킵 (다음 실행 시 자동 재시도).
  3) 예방적으로 DRIVER_RESTART_EVERY_N_LEAVES마다 드라이버를 통째로 재시작
     (장시간 세션 누적으로 인한 hang 가능성을 줄임).
"""

import os
import sys
import csv
import json
import logging
from typing import Optional

sys.path.append(os.path.join(os.path.dirname(__file__), ".."))
from common.utils import fetch_html, polite_sleep
from daiso.config import (
    CATEGORIES,
    MAIN_CATEGORIES,
    TARGET_PER_LEAF_CATEGORY,
    OUTPUT_DIR,
    OUTPUT_FILENAME,
    REQUEST_DELAY_SEC,
    CATEGORY_PAGE_DELAY_SEC,
    build_category_list_url,
    build_product_detail_url,
)
from daiso.daiso_selenium import (
    build_driver,
    fetch_product_links_for_leaf_category,
    SeleniumGetTimeout,
)
from daiso.daiso_detail_parser import parse_product_detail

logger = logging.getLogger("widgetrag_crawler")

FIELDNAMES = [
    "product_id",
    "product_name",
    "price",
    "category_main",
    "category_sub",
    "category_leaf",
    "description",
    "url",
]

PROGRESS_FILENAME = "daiso_progress.json"

# 몇 개의 leaf 카테고리마다 드라이버를 예방적으로 재시작할지.
# 너무 작으면 재시작 오버헤드(드라이버 기동 시간)가 커지고,
# 너무 크면 장시간 세션 누적으로 인한 hang 위험이 커진다.
DRIVER_RESTART_EVERY_N_LEAVES = 20

# get() 타임아웃 발생 시 드라이버 재시작 후 같은 leaf를 몇 번까지 재시도할지.
MAX_LEAF_RETRIES = 2


def leaf_key(category_main: str, category_sub: str, category_leaf: str) -> str:
    """완료 여부를 추적하기 위한 고유 키.
    '일회용패치'처럼 leaf명이 중복될 수 있으므로 3단계 전부를 합쳐 키로 쓴다."""
    return f"{category_main}|||{category_sub}|||{category_leaf}"


def load_progress(progress_path: str) -> set[str]:
    """완료된 leaf 키 집합을 불러온다. 파일이 없으면 빈 집합을 반환."""
    if not os.path.exists(progress_path):
        return set()
    try:
        with open(progress_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return set(data.get("completed_leaves", []))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"[daiso] 진행 로그 읽기 실패, 처음부터 시작: {e}")
        return set()


def save_progress(progress_path: str, completed_leaves: set[str]) -> None:
    with open(progress_path, "w", encoding="utf-8") as f:
        json.dump({"completed_leaves": sorted(completed_leaves)}, f, ensure_ascii=False, indent=2)


def load_existing_products(output_path: str) -> list[dict]:
    """기존 CSV가 있으면 불러와서 이어쓰기 위한 초기 리스트로 사용한다."""
    if not os.path.exists(output_path):
        return []
    try:
        with open(output_path, "r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            return list(reader)
    except OSError as e:
        logger.warning(f"[daiso] 기존 CSV 읽기 실패, 빈 상태로 시작: {e}")
        return []


def save_csv(products: list[dict], output_path: str) -> None:
    with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(products)


def restart_driver(driver):
    """기존 드라이버를 안전하게 종료하고 새 드라이버를 만들어 반환한다."""
    try:
        driver.quit()
    except Exception as e:
        logger.warning(f"[daiso] 기존 드라이버 종료 중 오류(무시): {e}")
    logger.info("[daiso] 드라이버 재시작 중...")
    return build_driver(headless=True)


def crawl_leaf_category(
    driver,
    main_code: str,
    sub_code: str,
    leaf_code: str,
    category_main: str,
    category_sub: str,
    category_leaf: str,
) -> list[dict]:
    """leaf(서브의서브) 카테고리 1개를 크롤링하여 상품 목록을 반환한다.

    driver.get() 단계에서 SeleniumGetTimeout이 발생하면 그대로 위로 전파한다.
    드라이버 재시작/재시도는 호출부(main 루프)의 책임이다.
    """
    category_url = build_category_list_url(main_code, sub_code, leaf_code)

    pd_nos = fetch_product_links_for_leaf_category(
        driver, category_url, target_count=TARGET_PER_LEAF_CATEGORY
    )

    if not pd_nos:
        logger.warning(
            f"[daiso] 상품 링크 0개, 스킵: {category_main} > {category_sub} > {category_leaf}"
        )
        return []

    products = []
    for pd_no in pd_nos:
        detail_url = build_product_detail_url(pd_no)
        html = fetch_html(detail_url)
        if not html:
            logger.warning(f"[daiso] 상세 페이지 요청 실패, 스킵: pdNo={pd_no}")
            continue

        parsed = parse_product_detail(html, pd_no)
        if not parsed:
            continue

        products.append(
            {
                "product_id": parsed["product_id"],
                "product_name": parsed["product_name"],
                "price": parsed["price"],
                "category_main": category_main,
                "category_sub": category_sub,
                "category_leaf": category_leaf,
                "description": parsed["description"],
                "url": detail_url,
            }
        )
        polite_sleep(REQUEST_DELAY_SEC)

    logger.info(
        f"[daiso] 수집 완료: {category_main} > {category_sub} > {category_leaf} "
        f"-> {len(products)}개"
    )
    return products


def crawl_leaf_category_with_retry(
    driver,
    main_code: str,
    sub_code: str,
    leaf_code: str,
    category_main: str,
    category_sub: str,
    category_leaf: str,
):
    """
    crawl_leaf_category를 호출하되, SeleniumGetTimeout 발생 시
    드라이버를 재시작하고 최대 MAX_LEAF_RETRIES번까지 재시도한다.

    반환값: (products, driver, success)
    - success=False면 이 leaf는 이번 실행에서 완료 처리하지 않고 스킵한다
      (completed_leaves에 추가하지 않으므로 다음 실행 시 자동 재시도됨).
    """
    last_error: Optional[Exception] = None

    for attempt in range(1, MAX_LEAF_RETRIES + 1):
        try:
            products = crawl_leaf_category(
                driver,
                main_code,
                sub_code,
                leaf_code,
                category_main,
                category_sub,
                category_leaf,
            )
            return products, driver, True

        except SeleniumGetTimeout as e:
            last_error = e
            logger.warning(
                f"[daiso] get() 타임아웃으로 leaf 실패 "
                f"(시도 {attempt}/{MAX_LEAF_RETRIES}): "
                f"{category_main} > {category_sub} > {category_leaf}"
            )
            driver = restart_driver(driver)
            # 재시도 전에 약간의 여유를 둬서 일시적 차단/지연이면 풀릴 시간을 준다.
            polite_sleep(CATEGORY_PAGE_DELAY_SEC)

        except Exception as e:
            # 예상치 못한 다른 예외는 일단 로그만 남기고 이 leaf는 실패 처리.
            # (driver는 살아있을 수도 있으니 굳이 재시작하지 않음)
            last_error = e
            logger.error(
                f"[daiso] 예상치 못한 오류로 leaf 실패: "
                f"{category_main} > {category_sub} > {category_leaf} - {e}"
            )
            break

    logger.error(
        f"[daiso] leaf 최종 실패, 이번 실행에서는 스킵 (다음 실행 시 재시도됨): "
        f"{category_main} > {category_sub} > {category_leaf} (마지막 오류: {last_error})"
    )
    return [], driver, False


def count_total_leaves() -> int:
    """진행률 표시용 - 전체 leaf 카테고리 개수."""
    total = 0
    for sub_dict in CATEGORIES.values():
        for sub_info in sub_dict.values():
            total += len(sub_info.get("leaves", {}))
    return total


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, OUTPUT_FILENAME)
    progress_path = os.path.join(OUTPUT_DIR, PROGRESS_FILENAME)

    completed_leaves = load_progress(progress_path)
    all_products: list[dict] = load_existing_products(output_path)

    if completed_leaves:
        logger.info(
            f"[daiso] 이어하기 모드: 이미 완료된 leaf {len(completed_leaves)}개를 스킵합니다. "
            f"(기존 수집 상품 {len(all_products)}개 유지)"
        )

    total_leaf_count = count_total_leaves()
    if total_leaf_count == 0:
        logger.error(
            "[daiso] CATEGORIES에 등록된 leaf 카테고리가 없습니다. "
            "config.py에서 카테고리 코드를 먼저 채워주세요."
        )
        return

    logger.info(f"[daiso] 전체 leaf 카테고리 개수: {total_leaf_count}")
    logger.info(
        f"[daiso] 예상 수집량: {total_leaf_count} x {TARGET_PER_LEAF_CATEGORY} "
        f"= {total_leaf_count * TARGET_PER_LEAF_CATEGORY}개"
    )

    driver = build_driver(headless=True)
    leaf_idx = 0
    leaves_since_restart = 0
    failed_leaves: list[str] = []

    try:
        for category_main, sub_dict in CATEGORIES.items():
            if not sub_dict:
                logger.warning(
                    f"[daiso] '{category_main}'의 카테고리 코드가 비어있습니다. 스킵."
                )
                continue

            main_code = MAIN_CATEGORIES[category_main]

            for category_sub, sub_info in sub_dict.items():
                sub_code = sub_info["sub_code"]
                leaves = sub_info.get("leaves", {})

                for category_leaf, leaf_code in leaves.items():
                    leaf_idx += 1
                    key = leaf_key(category_main, category_sub, category_leaf)

                    if key in completed_leaves:
                        logger.info(
                            f"[daiso] 진행률 {leaf_idx}/{total_leaf_count} "
                            f"(이미 완료, 스킵: {category_main} > {category_sub} > {category_leaf})"
                        )
                        continue

                    # 예방적 드라이버 재시작 (장시간 세션 누적으로 인한 hang 방지)
                    if leaves_since_restart >= DRIVER_RESTART_EVERY_N_LEAVES:
                        driver = restart_driver(driver)
                        leaves_since_restart = 0

                    logger.info(f"[daiso] 진행률 {leaf_idx}/{total_leaf_count}")

                    products, driver, success = crawl_leaf_category_with_retry(
                        driver,
                        main_code,
                        sub_code,
                        leaf_code,
                        category_main,
                        category_sub,
                        category_leaf,
                    )
                    leaves_since_restart += 1

                    if success:
                        all_products.extend(products)
                        completed_leaves.add(key)
                    else:
                        # 완료 처리하지 않음 -> 다음 실행 시 자동으로 다시 시도된다.
                        failed_leaves.append(
                            f"{category_main} > {category_sub} > {category_leaf}"
                        )

                    # robots.txt Crawl-delay: 30 존중 (카테고리 목록 페이지 재요청 간격)
                    polite_sleep(CATEGORY_PAGE_DELAY_SEC)

                    if leaf_idx % 10 == 0:
                        save_csv(all_products, output_path)
                        save_progress(progress_path, completed_leaves)
                        logger.info(
                            f"[daiso] 중간 저장 완료 ({leaf_idx}/{total_leaf_count}, "
                            f"누적 {len(all_products)}개)"
                        )
    finally:
        driver.quit()

    save_csv(all_products, output_path)
    save_progress(progress_path, completed_leaves)
    logger.info(f"[daiso] 전체 완료: 총 {len(all_products)}개 -> {output_path}")

    if failed_leaves:
        logger.warning(
            f"[daiso] 이번 실행에서 끝내 실패하여 스킵된 leaf {len(failed_leaves)}개 "
            f"(다음 실행 시 자동 재시도됨):"
        )
        for fl in failed_leaves:
            logger.warning(f"  - {fl}")


if __name__ == "__main__":
    main()