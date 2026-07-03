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
    private Company company;

    @Column(name = "name", length = 50)
    private String name;

    @Column(name = "email", length = 100, nullable = false, unique = true)
    private String email;

    @Column(name = "password", length = 100, nullable = false)
    private String password;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private Role role;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private MemberStatus status;

    public static Member createEmployee(Company company, String email, String encodedPassword, String name) {
        Member member = new Member();
        member.company = company;
        member.email = email;
        member.password = encodedPassword;
        member.name = name;
        member.role = Role.EMPLOYEE;
        member.status = MemberStatus.ACTIVE;
        return member;
    }

    public static Member createCompanyOwner(Company company, String email, String encodedPassword, String name) {
        Member member = new Member();
        member.company = company;
        member.email = email;
        member.password = encodedPassword;
        member.name = name;
        member.role = Role.COMPANY_OWNER;
        member.status = MemberStatus.PENDING;
        return member;
    }

    public void activate() {
        this.status = MemberStatus.ACTIVE;
    }

    public void reject() {
        this.status = MemberStatus.REJECTED;
    }

    public static Member createAdmin(
            Company company,
            String email,
            String encodedPassword,
            String name
    ) {
        Member member = new Member();

        member.company = company;
        member.email = email;
        member.password = encodedPassword;
        member.name = name;

        member.role = Role.ADMIN;
        member.status = MemberStatus.ACTIVE;

        return member;
    }

    public void changePassword(String encodedPassword) {
        this.password = encodedPassword;
    }
}