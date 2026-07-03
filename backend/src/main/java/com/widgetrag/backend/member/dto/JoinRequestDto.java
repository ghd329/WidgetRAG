package com.widgetrag.backend.member.dto;

public record JoinRequestDto(
        String clientCode,
        String email,
        String password,
        String name
) {
}