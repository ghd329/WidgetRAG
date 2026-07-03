package com.widgetrag.backend.member.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.member.dto.AdminMemberResponseDto;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import com.widgetrag.backend.member.entity.Role;

import java.util.List;

@Service
@RequiredArgsConstructor
public class AdminMemberService {

    private final MemberRepository memberRepository;

    @Transactional(readOnly = true)
    public List<AdminMemberResponseDto> getMembers() {
        List<Member> members = memberRepository.findAll();

        return members.stream()
                .map(member -> {
                    Company company = member.getCompany();

                    return new AdminMemberResponseDto(
                            member.getId(),
                            member.getName(),
                            member.getEmail(),
                            company.getId(),
                            company.getCompanyName(),
                            company.getClientCode(),
                            member.getRole(),
                            member.getStatus()
                    );
                })
                .toList();
    }

    @Transactional
    public void deleteMember(Long memberId) {
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalArgumentException("회원을 찾을 수 없습니다."));

        if (member.getRole() == Role.ADMIN) {
            throw new IllegalStateException("관리자 계정은 삭제할 수 없습니다.");
        }

        memberRepository.delete(member);
    }
}