package com.widgetrag.backend.company.service;

import com.widgetrag.backend.company.dto.AdminCompanyResponseDto;
import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.entity.CompanyStatus;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.entity.Role;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;


import java.util.List;

@Service
@RequiredArgsConstructor
public class AdminCompanyService {

    private final CompanyRepository companyRepository;
    private final MemberRepository memberRepository;

    @Transactional(readOnly = true)
    public List<AdminCompanyResponseDto> getPendingCompanies() {
        return toDtos(companyRepository.findByStatus(CompanyStatus.PENDING));
    }

    /**
     * 승인 대기/승인/반려를 모두 포함한 전체 기업 목록.
     * 관리자 화면의 상태별 집계(승인 대기 n개 / 총 승인 n개 / 총 반려 n개)에 사용합니다.
     * 시스템 회사(SYSTEM)는 가입으로 생긴 고객사가 아니라 관리자 계정을 담는 내부 레코드라
     * 집계가 부풀지 않도록 제외합니다.
     */
    @Transactional(readOnly = true)
    public List<AdminCompanyResponseDto> getCompanies() {
        List<Company> companies = companyRepository.findAll().stream()
                .filter(company -> !"SYSTEM".equals(company.getClientCode()))
                .toList();

        return toDtos(companies);
    }

    private List<AdminCompanyResponseDto> toDtos(List<Company> companies) {
        return companies.stream()
                .map(company -> {
                    Member owner = memberRepository.findByCompanyIdAndRole(
                            company.getId(),
                            Role.COMPANY_OWNER
                    ).orElse(null);

                    return new AdminCompanyResponseDto(
                            company.getId(),
                            company.getCompanyName(),
                            company.getClientCode(),
                            owner != null ? owner.getEmail() : "-",
                            owner != null ? owner.getName() : "-",
                            company.getStatus()
                    );
                })
                .toList();
    }

    @Transactional
    public void approveCompany(Long companyId) {
        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalArgumentException("회사를 찾을 수 없습니다."));

        company.approve();

        Member owner = memberRepository.findByCompanyIdAndRole(companyId, Role.COMPANY_OWNER)
                .orElseThrow(() -> new IllegalArgumentException("대표 회원을 찾을 수 없습니다."));

        owner.activate();
    }

    @Transactional
    public void rejectCompany(Long companyId) {
        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalArgumentException("회사를 찾을 수 없습니다."));

        company.reject();

        Member owner = memberRepository.findByCompanyIdAndRole(companyId, Role.COMPANY_OWNER)
                .orElseThrow(() -> new IllegalArgumentException("대표 회원을 찾을 수 없습니다."));

        owner.reject();
    }

    @Transactional
    public void deleteCompany(Long companyId) {
        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalArgumentException("회사를 찾을 수 없습니다."));

        if ("SYSTEM".equals(company.getClientCode())) {
            throw new IllegalStateException("시스템 회사는 삭제할 수 없습니다.");
        }

        List<Member> members = memberRepository.findByCompanyId(companyId);
        memberRepository.deleteAll(members);

        companyRepository.delete(company);
    }

}