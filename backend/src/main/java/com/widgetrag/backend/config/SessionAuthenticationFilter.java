package com.widgetrag.backend.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContext;
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
 *
 * 이미 SecurityContext가 채워져 있어도 그대로 신뢰하지 않습니다. Spring Security가 세션에
 * 저장해 둔 예전 SecurityContext가 남아 있을 수 있어, 그 값을 믿으면 재로그인으로 계정이
 * 바뀌어도 예전 권한이 계속 적용됩니다. 항상 세션 속성과 대조해 어긋나면 다시 만듭니다.
 */
@Component
public class SessionAuthenticationFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {

        HttpSession session = request.getSession(false);

        Object memberId = session != null ? session.getAttribute("memberId") : null;
        Object role = session != null ? session.getAttribute("role") : null;

        Authentication current = SecurityContextHolder.getContext().getAuthentication();

        if (memberId != null && role != null) {
            var authority = new SimpleGrantedAuthority("ROLE_" + role);

            // 앞선 요청에서 저장된 SecurityContext가 세션에 남아 있을 수 있습니다.
            // 그 값이 세션 속성과 어긋나면(재로그인으로 계정/권한이 바뀐 경우) 예전 권한이
            // 계속 적용되므로, 어긋날 때는 항상 세션 속성 기준으로 다시 만들어 덮어씁니다.
            boolean matchesSession = current != null
                    && memberId.equals(current.getPrincipal())
                    && current.getAuthorities().contains(authority);

            if (!matchesSession) {
                SecurityContext context = SecurityContextHolder.createEmptyContext();
                context.setAuthentication(new UsernamePasswordAuthenticationToken(
                        memberId,
                        null,
                        List.of(authority)
                ));
                SecurityContextHolder.setContext(context);
            }

        } else if (current != null) {
            // 세션에 로그인 정보가 없는데 인증만 남아 있는 경우(로그아웃/세션 만료 후 잔여 컨텍스트).
            // 세션이 유일한 인증 기준이므로 비워서 비로그인 상태로 되돌립니다.
            SecurityContextHolder.clearContext();
        }

        filterChain.doFilter(request, response);
    }
}
