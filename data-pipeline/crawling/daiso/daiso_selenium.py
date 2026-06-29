"""
다이소몰 카테고리 목록 페이지 크롤러 (Selenium)

다이소몰의 카테고리 목록 페이지(/ds/exhCtgr/...)는 완전 React CSR이라
requests로는 빈 셸(shell) HTML만 받아진다. Selenium으로 페이지를 띄우고
JS 렌더링이 끝난 뒤의 DOM에서 상품 링크(pdNo)를 추출한다.

주의:
- 이 모듈은 사용자 로컬(WSL) 환경에서 직접 실행/디버깅이 필요하다.
  실제 DOM 셀렉터는 사이트 구조 변경에 취약하므로, 최초 실행 시
  CSS 셀렉터가 맞는지 반드시 확인 후 진행할 것.
- robots.txt의 Crawl-delay: 30을 존중하여 카테고리 페이지 요청 간
  CATEGORY_PAGE_DELAY_SEC(기본 30초)를 둔다.

[패치 내역]
- driver.get() 자체가 WebDriver 프로토콜 레벨에서 무한 대기(120s 등)에 빠지는
  현상을 막기 위해 set_page_load_timeout()을 명시적으로 지정.
- get() 타임아웃 시 예외를 던지는 대신, 호출부(crawl_daiso.py)에서
  드라이버를 재시작할 수 있도록 SeleniumGetTimeout 예외로 래핑해서 올린다.
"""

import re
import time
import logging
from typing import Optional

from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, WebDriverException
from webdriver_manager.chrome import ChromeDriverManager

logger = logging.getLogger("widgetrag_crawler")

# 상품 링크 안에서 pdNo만 뽑아내는 패턴.
# 실제 링크 형태 예시: /pd/pdr/SCR_PDR_0001?pdNo=1058891
PD_NO_PATTERN = re.compile(r"pdNo=([0-9A-Za-z]+)")

# driver.get() 자체에 대한 타임아웃(초). 기존엔 설정이 없어 ChromeDriver
# 기본값(보통 매우 길거나 무제한)을 따라가며 120s read timeout으로 멈췄었음.
PAGE_LOAD_TIMEOUT_SEC = 20


class SeleniumGetTimeout(Exception):
    """driver.get() 호출이 PAGE_LOAD_TIMEOUT_SEC 내에 끝나지 않았을 때 발생."""
    pass


def build_driver(headless: bool = True) -> webdriver.Chrome:
    """Selenium Chrome 드라이버를 생성한다."""
    options = Options()
    if headless:
        options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1920,1080")
    # 이미지 로딩을 꺼서 페이지 로딩 자체를 가볍게 만들고,
    # 리소스 대기로 인한 hang 가능성을 줄인다.
    options.add_argument("--blink-settings=imagesEnabled=false")
    options.add_argument(
        "user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    )
    service = Service(ChromeDriverManager().install())
    driver = webdriver.Chrome(service=service, options=options)

    # driver.get() 자체가 끝없이 블로킹되는 것을 방지.
    # 이 값을 넘기면 Selenium이 TimeoutException을 던진다.
    driver.set_page_load_timeout(PAGE_LOAD_TIMEOUT_SEC)

    return driver


def safe_get(driver: webdriver.Chrome, url: str) -> None:
    """
    driver.get()을 호출하되, page load timeout에 걸려도 예외를 SeleniumGetTimeout
    으로 통일해서 던진다. 호출부에서 이걸 잡아 드라이버를 재시작할 수 있다.

    TimeoutException 발생 시 window.stop()으로 남은 로딩을 강제 중단한다.
    이미 받아둔 DOM 일부가 있을 수 있으므로, 호출부에서 이어서 셀렉터를
    조회해볼 여지를 남긴다 (단, 본 크롤러에서는 재시도가 더 안전하므로
    호출부에서는 보통 재시작 후 재시도한다).
    """
    try:
        driver.get(url)
    except TimeoutException as e:
        logger.warning(f"[daiso] driver.get() 타임아웃({PAGE_LOAD_TIMEOUT_SEC}s): {url}")
        try:
            driver.execute_script("window.stop();")
        except WebDriverException:
            # 드라이버 세션 자체가 죽어있으면 stop()도 실패할 수 있음.
            # 이 경우는 완전히 재시작이 필요하다는 신호.
            pass
        raise SeleniumGetTimeout(url) from e


def fetch_product_links_from_category(
    driver: webdriver.Chrome,
    category_url: str,
    target_count: int = 30,
    max_scroll: int = 10,
    render_wait_sec: float = 3.0,
) -> list[str]:
    """
    카테고리 목록 페이지(category_url)를 Selenium으로 열어
    상품 상세 링크(pdNo) 목록을 반환한다.

    다이소몰은 무한 스크롤 방식일 가능성이 높아, target_count를 채울
    때까지 스크롤을 반복한다. (최초 실행 시 실제 동작 확인 필요)

    driver.get() 단계에서 SeleniumGetTimeout이 발생하면 그대로 위로
    전파한다 (호출부에서 드라이버 재시작 후 재시도하도록).
    """
    safe_get(driver, category_url)

    # 초기 렌더링 대기.
    try:
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.TAG_NAME, "a"))
        )
    except TimeoutException:
        logger.warning(f"[daiso] 페이지 로드 타임아웃: {category_url}")
        return []

    time.sleep(render_wait_sec)

    pd_nos: list[str] = []
    seen: set[str] = set()
    scroll_count = 0

    while len(pd_nos) < target_count and scroll_count < max_scroll:
        anchors = driver.find_elements(By.CSS_SELECTOR, "a[href*='pdNo=']")
        for a in anchors:
            href = a.get_attribute("href") or ""
            m = PD_NO_PATTERN.search(href)
            if not m:
                continue
            pd_no = m.group(1)
            if pd_no in seen:
                continue
            seen.add(pd_no)
            pd_nos.append(pd_no)
            if len(pd_nos) >= target_count:
                break

        if len(pd_nos) >= target_count:
            break

        # 무한 스크롤 대비: 페이지 끝까지 스크롤 후 추가 렌더링 대기.
        driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
        time.sleep(1.5)
        scroll_count += 1

    return pd_nos[:target_count]


def fetch_product_links_for_leaf_category(
    driver: webdriver.Chrome,
    category_url: str,
    target_count: int = 30,
) -> list[str]:
    """leaf 카테고리 1개에 대해 상품 pdNo 목록을 가져오는 진입점.

    SeleniumGetTimeout은 호출부(crawl_daiso.py)에서 드라이버를 재시작하고
    재시도할 수 있도록 그대로 전파한다.
    """
    logger.info(f"[daiso] 카테고리 페이지 로드: {category_url}")
    pd_nos = fetch_product_links_from_category(driver, category_url, target_count)
    logger.info(f"[daiso] 추출된 pdNo 개수: {len(pd_nos)} ({category_url})")
    return pd_nos