package com.widgetrag.backend.member.dto;

// 응답 (공통)
public record SignupResponseDto(
        Long memberId,
        String clientCode,    // 시스템이 생성한 코드 - 신규 가입 시 이걸 안내해줘야 함
        String companyName,
        String email
) {}