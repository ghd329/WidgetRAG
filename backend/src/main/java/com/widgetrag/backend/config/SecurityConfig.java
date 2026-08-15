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

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
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
                        .sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED))

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
