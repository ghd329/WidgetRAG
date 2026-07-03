package com.widgetrag.backend.member.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.entity.CompanyStatus;
import com.widgetrag.backend.company.exception.CompanyNotFoundException;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.dto.JoinRequestDto;
import com.widgetrag.backend.member.dto.LoginRequestDto;
import com.widgetrag.backend.member.dto.LoginResponseDto;
import com.widgetrag.backend.member.dto.SignupRequestDto;
import com.widgetrag.backend.member.dto.SignupResponseDto;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.entity.MemberStatus;
import com.widgetrag.backend.member.exception.DuplicateEmailException;
import com.widgetrag.backend.member.exception.InvalidCredentialsException;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import com.widgetrag.backend.member.dto.ChangePasswordRequestDto;
import com.widgetrag.backend.member.dto.WithdrawRequestDto;
import com.widgetrag.backend.common.PasswordValidator;
import com.widgetrag.backend.member.dto.FindPasswordRequestDto;

import java.util.UUID;

@Service
@RequiredArgsConstructor
public class MemberService {

    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final PasswordEncoder passwordEncoder;

    // 기업 회원가입: 회사 생성 신청 + 대표 계정 생성
    @Transactional
    public SignupResponseDto signup(SignupRequestDto request) {

        if (memberRepository.existsByEmail(request.email())) {
            throw new DuplicateEmailException(request.email());
        }

        PasswordValidator.validate(request.password());

        String clientCode = generateUniqueClientCode();

        Company company = Company.create(clientCode, request.companyName());
        companyRepository.save(company);

        String encodedPassword = passwordEncoder.encode(request.password());

        Member member = Member.createCompanyOwner(
                company,
                request.email(),
                encodedPassword,
                request.name()
        );

        memberRepository.save(member);

        return new SignupResponseDto(
                member.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getEmail()
        );
    }
    // 일반 사원 회원가입: 승인된 회사에만 가입 가능
    @Transactional
    public SignupResponseDto join(JoinRequestDto request) {

        if (memberRepository.existsByEmail(request.email())) {
            throw new DuplicateEmailException(request.email());
        }

        PasswordValidator.validate(request.password());

        Company company = companyRepository.findByClientCode(request.clientCode())
                .orElseThrow(() -> new CompanyNotFoundException(request.clientCode()));

        if (company.getStatus() != CompanyStatus.APPROVED) {
            throw new IllegalStateException("관리자 승인된 회사만 사원 가입이 가능합니다.");
        }

        String encodedPassword = passwordEncoder.encode(request.password());

        Member member = Member.createEmployee(
                company,
                request.email(),
                encodedPassword,
                request.name()
        );

        memberRepository.save(member);

        return new SignupResponseDto(
                member.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getEmail()
        );
    }

    // 로그인
    @Transactional(readOnly = true)
    public LoginResponseDto login(LoginRequestDto request) {

        Member member = memberRepository.findByEmail(request.email())
                .orElseThrow(InvalidCredentialsException::new);

        if (!passwordEncoder.matches(request.password(), member.getPassword())) {
            throw new InvalidCredentialsException();
        }

        if (member.getStatus() != MemberStatus.ACTIVE) {
            throw new IllegalStateException("관리자 승인 후 로그인이 가능합니다.");
        }

        Company company = member.getCompany();

        return new LoginResponseDto(
                member.getId(),
                member.getEmail(),
                company.getId(),
                company.getClientCode(),
                company.getCompanyName(),
                member.getRole()
        );
    }

    private String generateUniqueClientCode() {
        String code;
        do {
            code = "shop_" + UUID.randomUUID().toString().substring(0, 8);
        } while (companyRepository.existsByClientCode(code));
        return code;
    }

    @Transactional
    public void changePassword(ChangePasswordRequestDto request) {

        Member member = memberRepository.findById(request.memberId())
                .orElseThrow(() -> new IllegalArgumentException("회원을 찾을 수 없습니다."));

        if (!passwordEncoder.matches(request.currentPassword(), member.getPassword())) {
            throw new IllegalArgumentException("현재 비밀번호가 일치하지 않습니다.");
        }

        if (!request.newPassword().equals(request.newPasswordConfirm())) {
            throw new IllegalArgumentException("새 비밀번호가 일치하지 않습니다.");
        }

        PasswordValidator.validate(request.newPassword());

        member.changePassword(passwordEncoder.encode(request.newPassword()));
    }

    @Transactional
    public void withdraw(WithdrawRequestDto request) {

        Member member = memberRepository.findById(request.memberId())
                .orElseThrow(() -> new IllegalArgumentException("회원을 찾을 수 없습니다."));

        if (!passwordEncoder.matches(request.password(), member.getPassword())) {
            throw new IllegalArgumentException("비밀번호가 일치하지 않습니다.");
        }

        memberRepository.delete(member);
    }

    @Transactional
    public String findPassword(FindPasswordRequestDto request) {

        Member member = memberRepository.findByEmail(request.email())
                .orElseThrow(() -> new IllegalArgumentException("가입된 이메일이 없습니다."));

        String tempPassword = "Temp!" + UUID.randomUUID().toString().substring(0, 8);

        member.changePassword(passwordEncoder.encode(tempPassword));

        return tempPassword;
    }
        
}