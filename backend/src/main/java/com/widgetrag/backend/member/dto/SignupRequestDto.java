package com.widgetrag.backend.member.dto;

// 신규 가입
public record SignupRequestDto(
        String companyName,
        String email,
        String password
) {}