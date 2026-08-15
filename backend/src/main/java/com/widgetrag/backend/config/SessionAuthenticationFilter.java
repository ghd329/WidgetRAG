package com.widgetrag.backend.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;

/**
 * 로그인은 MemberController가 HttpSession에 memberId/role을 담는 방식으로 동작하고
 * SecurityContextHolder는 사용하지 않습니다.
 * 그 상태로 authorizeHttpRequests에 authenticated()를 걸면 로그인한 사용자까지 전부 차단되므로,
 * 세션 속성을 읽어 SecurityContext를 채워주는 필터를 둡니다.
 *
 * 세션이 여전히 인증의 단일 기준이며, 이 필터는 그 값을 Spring Security가 이해하는 형태로
 * 변환하기만 합니다. 컨트롤러의 기존 세션 조회 코드는 그대로 동작합니다.
 */
@Component
public class SessionAuthenticationFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {

        if (SecurityContextHolder.getContext().getAuthentication() == null) {
            HttpSession session = request.getSession(false);

            if (session != null) {
                Object memberId = session.getAttribute("memberId");
                Object role = session.getAttribute("role");

                if (memberId != null && role != null) {
                    var authentication = new UsernamePasswordAuthenticationToken(
                            memberId,
                            null,
                            List.of(new SimpleGrantedAuthority("ROLE_" + role))
                    );
                    SecurityContextHolder.getContext().setAuthentication(authentication);
                }
            }
        }

        filterChain.doFilter(request, response);
    }
}
