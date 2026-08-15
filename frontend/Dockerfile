# WidgetRag - frontend (정적 HTML/CSS/Vanilla JS, 번들러 없음)
# 빌드 스테이지 불필요 — nginx에 정적 파일만 COPY

FROM nginx:alpine

COPY . /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# nginx.conf는 빌드 컨텍스트에 있어야 위 COPY가 동작하므로 .dockerignore로 막을 수 없습니다.
# 대신 웹 루트에 복사된 사본을 제거해 설정 파일이 외부에 노출되지 않도록 합니다.
# 베이스 이미지의 기본 환영 페이지(index.html)도 함께 제거합니다.
RUN rm -f /usr/share/nginx/html/nginx.conf /usr/share/nginx/html/index.html

EXPOSE 80

# localhost가 아니라 127.0.0.1을 씁니다.
# alpine에서 localhost는 ::1(IPv6)로 먼저 해석되는데 nginx는 listen 80(IPv4)만 바인딩해
# 헬스체크가 Connection refused로 실패합니다.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1/login/company-login.html > /dev/null || exit 1
