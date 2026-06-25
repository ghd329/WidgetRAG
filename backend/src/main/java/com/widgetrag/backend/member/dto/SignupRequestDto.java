package com.widgetrag.backend.member.dto;

public record SignupRequestDto(
        String clientCode,      // 필수 - 상점 코드 (신규/기존 공통)
        String companyName,     // 신규 상점일 때만 필수, 기존이면 null 허용
        String email,
        String password
) {}