package com.widgetrag.backend.member.dto;

public record SignupRequestDto(
        String companyName,
        String email,
        String password,
        String name
) {
}