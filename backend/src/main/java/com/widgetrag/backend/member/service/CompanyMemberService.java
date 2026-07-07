package com.widgetrag.backend.member.service;

import com.widgetrag.backend.member.dto.CompanyMemberResponseDto;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.entity.MemberStatus;
import com.widgetrag.backend.member.entity.Role;
import com.widgetrag.backend.member.exception.MemberAccessDeniedException;
import com.widgetrag.backend.member.exception.MemberNotFoundException;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
public class CompanyMemberService {

    private final MemberRepository memberRepository;

    @Transactional(readOnly = true)
    public List<CompanyMemberResponseDto> getPendingMembers(Long companyId) {
        return memberRepository.findByCompanyIdAndStatusAndRole(companyId, MemberStatus.PENDING, Role.EMPLOYEE)
                .stream()
                .map(this::toDto)
                .toList();
    }

    @Transactional
    public void approveMember(Long companyId, Long memberId) {
        Member member = getMemberInCompany(companyId, memberId);
        member.activate();
    }

    @Transactional
    public void rejectMember(Long companyId, Long memberId) {
        Member member = getMemberInCompany(companyId, memberId);
        member.reject();
    }

    private Member getMemberInCompany(Long companyId, Long memberId) {
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new MemberNotFoundException(memberId));

        if (!member.getCompany().getId().equals(companyId)) {
            throw new MemberAccessDeniedException();
        }

        return member;
    }

    private CompanyMemberResponseDto toDto(Member member) {
        return new CompanyMemberResponseDto(
                member.getId(),
                member.getName(),
                member.getEmail(),
                member.getRole(),
                member.getStatus()
        );
    }
}
