package com.widgetrag.backend.config;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;

/**
 * 최초 기동 시 관리자 계정을 1회 생성합니다.
 *
 * 계정 정보는 코드에 두지 않고 환경변수(ADMIN_EMAIL / ADMIN_PASSWORD)로 주입합니다.
 * 비밀번호가 비어 있으면 계정을 만들지 않습니다 — 기본 비밀번호를 심어두면 배포 주소만
 * 알면 누구나 관리자 콘솔에 로그인할 수 있기 때문입니다.
 *
 * 이미 같은 이메일의 계정이 있으면 아무것도 하지 않습니다. 따라서 ADMIN_PASSWORD를 바꿔도
 * 기존 계정의 비밀번호는 바뀌지 않습니다. 운영 중인 계정의 비밀번호 변경은
 * PATCH /api/members/password 로 처리하세요.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class AdminInitializer {

    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final PasswordEncoder passwordEncoder;

    @Value("${widgetrag.admin.email}")
    private String adminEmail;

    @Value("${widgetrag.admin.password}")
    private String adminPassword;

    @PostConstruct
    public void init() {

        if (memberRepository.existsByEmail(adminEmail)) {
            return;
        }

        if (adminPassword == null || adminPassword.isBlank()) {
            log.warn("ADMIN_PASSWORD가 설정되지 않아 관리자 계정({})을 생성하지 않았습니다. "
                    + "관리자 콘솔을 쓰려면 환경변수를 설정한 뒤 다시 기동하세요.", adminEmail);
            return;
        }

        // 관리자 계정만 지워진 상태로 다시 기동하면 SYSTEM 회사가 중복 생성되므로
        // 이미 있으면 그것을 재사용합니다.
        Company company = companyRepository.findByClientCode("SYSTEM")
                .orElseGet(() -> companyRepository.save(
                        Company.createSystemCompany("SYSTEM", "WidgetRAG")
                ));

        Member admin = Member.createAdmin(
                company,
                adminEmail,
                passwordEncoder.encode(adminPassword),
                "관리자"
        );

        memberRepository.save(admin);

        log.info("관리자 계정을 생성했습니다: {}", adminEmail);
    }
}
