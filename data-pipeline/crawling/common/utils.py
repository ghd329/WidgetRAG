"""
공통 유틸리티 함수
- HTTP 요청 (재시도 포함)
- 가격 문자열 정제
- 로깅 설정
"""
import time
import logging
import requests
from typing import Optional

logger = logging.getLogger("widgetrag_crawler")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)

DEFAULT_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    )
}


def fetch_html(
    url: str,
    headers: Optional[dict] = None,
    timeout: int = 10,
    max_retries: int = 3,
    retry_delay: float = 1.5,
) -> Optional[str]:
    """
    재시도 로직이 포함된 GET 요청.
    실패 시 None 반환 (크롤러가 멈추지 않고 다음 항목으로 넘어가도록).
    """
    headers = headers or DEFAULT_HEADERS
    for attempt in range(1, max_retries + 1):
        try:
            resp = requests.get(url, headers=headers, timeout=timeout)
            resp.raise_for_status()
            resp.encoding = resp.apparent_encoding or "utf-8"
            return resp.text
        except requests.exceptions.RequestException as e:
            logger.warning(f"[fetch_html] 시도 {attempt}/{max_retries} 실패: {url} ({e})")
            if attempt < max_retries:
                time.sleep(retry_delay)
    logger.error(f"[fetch_html] 최종 실패: {url}")
    return None


def clean_price(raw_price: str) -> Optional[int]:
    """
    '14,900원' -> 14900 (int)
    숫자가 없으면 None
    """
    if not raw_price:
        return None
    digits = "".join(ch for ch in raw_price if ch.isdigit())
    return int(digits) if digits else None


def polite_sleep(seconds: float = 1.0) -> None:
    """서버 부담을 줄이기 위한 요청 간 대기."""
    time.sleep(seconds)