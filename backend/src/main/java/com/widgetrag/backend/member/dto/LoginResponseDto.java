package com.widgetrag.backend.member.dto;

public record LoginResponseDto(
        Long memberId,
        String email,
        String clientCode,
        String companyName
) {}