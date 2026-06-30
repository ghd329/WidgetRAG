package com.widgetrag.backend.member.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.exception.CompanyNotFoundException;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.dto.JoinRequestDto;
import com.widgetrag.backend.member.dto.LoginRequestDto;
import com.widgetrag.backend.member.dto.LoginResponseDto;
import com.widgetrag.backend.member.dto.SignupRequestDto;
import com.widgetrag.backend.member.dto.SignupResponseDto;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.exception.DuplicateEmailException;
import com.widgetrag.backend.member.exception.InvalidCredentialsException;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
@RequiredArgsConstructor
public class MemberService {

    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final PasswordEncoder passwordEncoder;

    @Transactional
    public SignupResponseDto signup(SignupRequestDto request) {

        if (memberRepository.existsByEmail(request.email())) {
            throw new DuplicateEmailException(request.email());
        }

        String clientCode = generateUniqueClientCode();
        Company company = Company.create(clientCode, request.companyName());
        companyRepository.save(company);

        String encodedPassword = passwordEncoder.encode(request.password());
        Member member = Member.create(company, request.email(), encodedPassword);
        memberRepository.save(member);

        return new SignupResponseDto(
                member.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getEmail()
        );
    }

    @Transactional
    public SignupResponseDto join(JoinRequestDto request) {

        if (memberRepository.existsByEmail(request.email())) {
            throw new DuplicateEmailException(request.email());
        }

        Company company = companyRepository.findByClientCode(request.clientCode())
                .orElseThrow(() -> new CompanyNotFoundException(request.clientCode()));

        String encodedPassword = passwordEncoder.encode(request.password());
        Member member = Member.create(company, request.email(), encodedPassword);
        memberRepository.save(member);

        return new SignupResponseDto(
                member.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getEmail()
        );
    }

    @Transactional(readOnly = true)
    public LoginResponseDto login(LoginRequestDto request) {

        Member member = memberRepository.findByEmail(request.email())
                .orElseThrow(InvalidCredentialsException::new);

        if (!passwordEncoder.matches(request.password(), member.getPassword())) {
            throw new InvalidCredentialsException();
        }

        Company company = member.getCompany();

        return new LoginResponseDto(
                member.getId(),
                member.getEmail(),
                company.getId(),
                company.getClientCode(),
                company.getCompanyName()
        );
    }

    // client_code 중복 가능성을 사실상 0으로 만들기 위해 존재 여부 체크까지 포함
    private String generateUniqueClientCode() {
        String code;
        do {
            code = "shop_" + UUID.randomUUID().toString().substring(0, 8);
        } while (companyRepository.existsByClientCode(code));
        return code;
    }
}