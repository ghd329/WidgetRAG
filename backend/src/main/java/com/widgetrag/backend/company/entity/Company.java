package com.widgetrag.backend.company.entity;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@Table(name = "company")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class Company {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @Column(name = "client_code", length = 50, nullable = false, unique = true)
    private String clientCode;

    @Column(name = "company_name", length = 100, nullable = false)
    private String companyName;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private CompanyStatus status;

    /**
     * 일반 기업 회원가입용
     * 최초 상태는 승인 대기(PENDING)
     */
    public static Company create(String clientCode, String companyName) {
        Company company = new Company();
        company.clientCode = clientCode;
        company.companyName = companyName;
        company.status = CompanyStatus.PENDING;
        return company;
    }

    /**
     * 시스템 회사(관리자 계정) 생성용
     * 최초 상태는 승인 완료(APPROVED)
     */
    public static Company createSystemCompany(String clientCode, String companyName) {
        Company company = new Company();
        company.clientCode = clientCode;
        company.companyName = companyName;
        company.status = CompanyStatus.APPROVED;
        return company;
    }

    public void approve() {
        this.status = CompanyStatus.APPROVED;
    }

    public void reject() {
        this.status = CompanyStatus.REJECTED;
    }
}