# syntax=docker/dockerfile:1
# WidgetRag - backend (Spring Boot 4.1 / Java 17 / Maven)
# API 전담 서비스입니다. 정적 리소스는 위젯 스크립트(static/widget.js) 하나뿐이고,
# admin/company/customer 화면은 frontend(nginx) 컨테이너가 서빙합니다.

# ---- Build stage ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app

# dependency:go-offline은 쓰지 않습니다.
# 플러그인 의존성까지 전부 내려받으려 해서 매우 느리고, 실패도 잦습니다.
# 대신 BuildKit 캐시 마운트로 ~/.m2를 빌드 간에 재사용합니다.
# → 첫 빌드만 의존성을 받고, 이후 소스만 바뀌면 다운로드가 없습니다.
COPY pom.xml .
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package -DskipTests

# ---- Runtime stage ----
FROM eclipse-temurin:17-jre
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 1001 -m appuser

COPY --from=build /app/target/*.jar app.jar

# CSV 업로드 파일 저장 경로 (application-docker.yaml의 storage.base-path)
RUN mkdir -p /data/widgetrag && chown -R appuser:appuser /data/widgetrag /app

USER appuser

# 기본 프로필을 docker로 고정합니다.
# 이게 없으면 application.yaml의 profiles.active=local이 적용되어
# localhost:5432 접속과 윈도우 경로(\\wsl$\...) 때문에 기동에 실패합니다.
ENV SPRING_PROFILES_ACTIVE=docker \
    JAVA_OPTS="-XX:MaxRAMPercentage=75.0"

EXPOSE 8080

# actuator 의존성이 없어 별도 health 엔드포인트가 없습니다.
# 정적 리소스 widget.js 응답으로 기동 여부만 확인합니다.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD curl -fsS http://localhost:8080/widget.js > /dev/null || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
