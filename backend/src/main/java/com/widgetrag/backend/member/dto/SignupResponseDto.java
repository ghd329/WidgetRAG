package com.widgetrag.backend.member.dto;

public record SignupResponseDto(
        Long memberId,
        String clientCode,
        String companyName,
        String email,
        boolean isNewCompany // 신규 회사로 가입했는지, 기존 회사에 합류했는지
) {}