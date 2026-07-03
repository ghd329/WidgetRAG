package com.widgetrag.backend.config;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class AdminInitializer {

    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final PasswordEncoder passwordEncoder;

    @PostConstruct
    public void init() {

        if (memberRepository.existsByEmail("admin@widgetrag.com")) {
            return;
        }

        Company company = Company.createSystemCompany(
                "SYSTEM",
                "WidgetRAG"
        );

        companyRepository.save(company);

        Member admin = Member.createAdmin(
                company,
                "admin@widgetrag.com",
                passwordEncoder.encode("1234"),
                "관리자"
        );

        memberRepository.save(admin);
    }
}