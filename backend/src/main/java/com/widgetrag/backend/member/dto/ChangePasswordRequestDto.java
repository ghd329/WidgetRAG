package com.widgetrag.backend.member.dto;

public record ChangePasswordRequestDto(
        Long memberId,
        String currentPassword,
        String newPassword,
        String newPasswordConfirm
) {
}