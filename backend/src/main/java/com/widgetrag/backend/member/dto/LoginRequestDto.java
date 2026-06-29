package com.widgetrag.backend.member.dto;

public record LoginRequestDto(
        String email,
        String password
) {}