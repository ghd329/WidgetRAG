package com.widgetrag.backend.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.Arrays;
import java.util.List;

@Configuration
public class SecurityConfig {

    private final SessionAuthenticationFilter sessionAuthenticationFilter;

    /**
     * 위젯이 설치되는 고객사 도메인 등 CORS를 허용할 오리진 목록.
     * 예: https://shop-a.com,https://shop-b.com
     * 로컬 개발 기본값만 두고, 배포 시 CORS_ALLOWED_ORIGINS로 실제 도메인을 지정하세요.
     */
    @Value("${widgetrag.cors.allowed-origins}")
    private String allowedOrigins;

    public SecurityConfig(SessionAuthenticationFilter sessionAuthenticationFilter) {
        this.sessionAuthenticationFilter = sessionAuthenticationFilter;
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();

        // 첫 번째로 매칭되는 규칙이 적용되므로, 더 구체적인 /api/chat을 먼저 등록합니다.
        source.registerCorsConfiguration("/api/chat", widgetChatCorsConfiguration());
        source.registerCorsConfiguration("/**", consoleCorsConfiguration());

        return source;
    }

    /**
     * 고객사 쇼핑몰에 설치된 위젯이 호출하는 경로.
     *
     * 위젯은 쿠키를 보내지 않으므로(widget.js의 fetch가 credentials를 쓰지 않음)
     * 오리진을 열어도 로그인 세션이 노출되지 않습니다. 반대로 오리진을 제한하면
     * 고객사가 늘어날 때마다 환경변수 수정과 백엔드 재기동이 필요해지고,
     * 재기동 시 인메모리 세션이 모두 끊깁니다.
     *
     * CORS는 브라우저에만 적용되는 규칙이라 서버 대 서버 호출은 어차피 막지 못합니다.
     * 즉 여기서의 제한은 정상적인 위젯 설치만 막을 뿐 실질적인 방어가 되지 않습니다.
     * clientCode 도용 같은 무단 사용을 막으려면 회사별 허용 도메인 검증과
     * 호출 빈도 제한이 필요하며, 그것은 CORS와 별개의 작업입니다.
     */
    private CorsConfiguration widgetChatCorsConfiguration() {
        CorsConfiguration config = new CorsConfiguration();

        config.setAllowedOrigins(List.of("*"));
        config.setAllowedMethods(List.of("POST", "OPTIONS"));
        config.setAllowedHeaders(List.of("Content-Type"));
        config.setAllowCredentials(false); // 쿠키를 주고받지 않습니다. "*" 허용의 전제 조건입니다.
        config.setMaxAge(3600L);

        return config;
    }

    /**
     * 관리자/회사 콘솔 등 세션 쿠키를 사용하는 나머지 경로.
     */
    private CorsConfiguration consoleCorsConfiguration() {
        CorsConfiguration config = new CorsConfiguration();

        // allowCredentials=true 상태에서 오리진을 사실상 전부 허용하면(http://**),
        // CSRF가 비활성인 이 구성에서는 임의 사이트가 로그인 세션으로 API를 호출할 수 있습니다.
        // 따라서 허용 오리진을 명시 목록으로 제한합니다.
        config.setAllowedOriginPatterns(
                Arrays.stream(allowedOrigins.split(","))
                        .map(String::trim)
                        .filter(s -> !s.isEmpty())
                        .toList()
        );
        config.setAllowedMethods(List.of("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(List.of("*"));
        config.setAllowCredentials(true); // 세션 쿠키 주고받으려면 필수
        config.setMaxAge(3600L);

        return config;
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
                .cors(cors -> cors.configurationSource(corsConfigurationSource()))
                // 세션 쿠키 기반이라 CSRF 토큰을 켜는 것이 원칙이지만,
                // 프론트가 순수 정적 HTML이라 토큰 발급/전달 흐름이 없습니다.
                // 대신 위의 CORS 오리진 제한 + SameSite 쿠키 설정으로 방어합니다.
                .csrf(csrf -> csrf.disable())
                .sessionManagement(session -> session
                        .sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED)
                        // 로그인은 MemberController가 직접 처리하므로, Spring Security는 인증이 붙은
                        // 첫 요청을 "방금 로그인한 요청"으로 오인해 그때 세션 ID를 교체합니다.
                        // 그 순간 진행 중이던 다른 요청은 무효가 된 ID를 들고 있어 401로 떨어집니다.
                        // 세션 고정 방어는 로그인에서 기존 세션을 invalidate하며 이미 처리하므로,
                        // 여기서의 추가 교체는 끕니다.
                        .sessionFixation(fixation -> fixation.none()))

                // 인증 실패 시 로그인 폼으로 리다이렉트하지 않고 401을 그대로 반환합니다.
                // (프론트가 fetch로만 호출하므로 리다이렉트는 오히려 디버깅을 어렵게 만듭니다)
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED)))

                .addFilterBefore(sessionAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)

                .authorizeHttpRequests(auth -> auth
                        // --- CORS preflight ---
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()

                        // 예외 발생 시 /error로 포워딩됩니다. 여기가 막히면 실제 오류가
                        // 401로 덮여 원인 파악이 어려워집니다.
                        .requestMatchers("/error").permitAll()

                        // Swagger UI. docker 프로필에서는 springdoc 자체를 비활성화하므로
                        // 이 규칙은 로컬 개발에서만 의미가 있습니다.
                        .requestMatchers("/swagger-ui/**", "/v3/api-docs/**", "/swagger-ui.html").permitAll()

                        // --- 비로그인 접근이 필요한 공개 API ---
                        // 가입/로그인/비밀번호 찾기
                        .requestMatchers(HttpMethod.POST,
                                "/api/members/signup",
                                "/api/members/join",
                                "/api/members/login",
                                "/api/members/find-password").permitAll()
                        // 직원 가입 화면의 회사 선택 목록
                        .requestMatchers(HttpMethod.GET, "/api/companies/approved").permitAll()
                        // 고객사 사이트에 설치된 위젯이 호출 (비로그인 고객)
                        .requestMatchers(HttpMethod.POST, "/api/chat").permitAll()
                        // 데모샵 상품 목록 (clientCode로 공개 조회)
                        .requestMatchers(HttpMethod.GET, "/api/product-items/public/**").permitAll()
                        // 위젯 스크립트 정적 파일
                        .requestMatchers(HttpMethod.GET, "/widget.js").permitAll()

                        // --- 관리자 전용 ---
                        .requestMatchers("/api/admin/**").hasRole("ADMIN")

                        // --- 회사 관리자 전용 (직원 승인/거절) ---
                        .requestMatchers("/api/company/members/**").hasAnyRole("ADMIN", "COMPANY_OWNER")

                        // --- 나머지는 로그인 필요 ---
                        .anyRequest().authenticated()
                );

        return http.build();
    }
}
