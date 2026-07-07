package com.widgetrag.backend.member.dto;

import com.widgetrag.backend.member.entity.MemberStatus;
import com.widgetrag.backend.member.entity.Role;

public record CompanyMemberResponseDto(
        Long memberId,
        String name,
        String email,
        Role role,
        MemberStatus status
) {
}
