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
    private String clientCode; // 예: cloth_shop, 위젯/WSL/OpenSearch 기준 키

    @Column(name = "company_name", length = 100, nullable = false)
    private String companyName;

    public static Company create(String clientCode, String companyName) {
        Company company = new Company();
        company.clientCode = clientCode;
        company.companyName = companyName;
        return company;
    }
}