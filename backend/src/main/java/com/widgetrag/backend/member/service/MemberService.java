package com.widgetrag.backend.member.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.exception.CompanyNameRequiredException;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.dto.SignupRequestDto;
import com.widgetrag.backend.member.dto.SignupResponseDto;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.exception.DuplicateEmailException;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class MemberService {

    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final PasswordEncoder passwordEncoder;

    @Transactional
    public SignupResponseDto signup(SignupRequestDto request) {

        // 1. 이메일 중복 체크 (신규/기존 회사 여부와 무관하게 항상 검증)
        if (memberRepository.existsByEmail(request.email())) {
            throw new DuplicateEmailException(request.email());
        }

        // 2. 상점 코드 존재 여부로 분기
        boolean isNewCompany = !companyRepository.existsByClientCode(request.clientCode());

        Company company;
        if (isNewCompany) {
            // 신규 상점 → companyName 필수
            if (request.companyName() == null || request.companyName().isBlank()) {
                throw new CompanyNameRequiredException();
            }
            company = Company.create(request.clientCode(), request.companyName());
            companyRepository.save(company);
        } else {
            // 기존 상점 → 조회해서 그대로 사용
            company = companyRepository.findByClientCode(request.clientCode())
                    .orElseThrow(() -> new IllegalStateException("상점 코드 조회 실패")); // existsBy 직후라 사실상 발생 안 함
        }

        // 3. 비밀번호 암호화 후 Member 생성
        String encodedPassword = passwordEncoder.encode(request.password());
        Member member = Member.create(company, request.email(), encodedPassword);
        memberRepository.save(member);

        return new SignupResponseDto(
                member.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getEmail(),
                isNewCompany
        );
    }
}