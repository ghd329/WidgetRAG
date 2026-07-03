package com.widgetrag.backend.member.dto;

import com.widgetrag.backend.member.entity.MemberStatus;
import com.widgetrag.backend.member.entity.Role;

public record AdminMemberResponseDto(
        Long memberId,
        String name,
        String email,
        Long companyId,
        String companyName,
        String clientCode,
        Role role,
        MemberStatus status
) {
}