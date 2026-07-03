package com.widgetrag.backend.member.dto;

public record WithdrawRequestDto(
        Long memberId,
        String password
) {
}