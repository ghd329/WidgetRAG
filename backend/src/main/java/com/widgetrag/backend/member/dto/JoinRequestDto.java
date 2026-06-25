package com.widgetrag.backend.member.dto;

// 기존 회사 합류
public record JoinRequestDto(
        String clientCode,
        String email,
        String password
) {}
