package com.widgetrag.backend.member.entity;

import com.widgetrag.backend.company.entity.Company;
import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@Table(name = "member")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class Member {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "company_id", nullable = false)
    private Company company; // 이 계정이 속한 회사

    @Column(name = "email", length = 100, nullable = false, unique = true)
    private String email;

    @Column(name = "password", length = 100, nullable = false)
    private String password; // 암호화된 값만 저장

    public static Member create(Company company, String email, String encodedPassword) {
        Member member = new Member();
        member.company = company;
        member.email = email;
        member.password = encodedPassword;
        return member;
    }
}