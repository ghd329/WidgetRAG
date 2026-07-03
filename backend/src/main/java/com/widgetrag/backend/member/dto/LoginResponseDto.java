package com.widgetrag.backend.member.dto;

import com.widgetrag.backend.member.entity.Role;

public record LoginResponseDto(
        Long memberId,
        String email,
        Long companyId,
        String clientCode,
        String companyName,
        Role role
) {
}