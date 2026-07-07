package com.widgetrag.backend.member.repository;

import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.entity.MemberStatus;
import com.widgetrag.backend.member.entity.Role;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.List;

public interface MemberRepository extends JpaRepository<Member, Long> {

    Optional<Member> findByEmail(String email);

    boolean existsByEmail(String email);

    Optional<Member> findByCompanyIdAndRole(Long companyId, Role role);

    List<Member> findByCompanyId(Long companyId);

    List<Member> findByCompanyIdAndStatusAndRole(Long companyId, MemberStatus status, Role role);
}