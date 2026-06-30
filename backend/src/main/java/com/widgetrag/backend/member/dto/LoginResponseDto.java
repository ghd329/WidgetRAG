package com.widgetrag.backend.member.dto;

public record LoginResponseDto(
        Long memberId,
        String email,
        Long companyId,
        String clientCode,
        String companyName
) {}