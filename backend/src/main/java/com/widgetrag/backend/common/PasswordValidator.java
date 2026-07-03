package com.widgetrag.backend.common;

import java.util.regex.Pattern;

public final class PasswordValidator {

    private static final Pattern PASSWORD_PATTERN = Pattern.compile(
            "^(?=.*[A-Za-z])(?=.*\\d)(?=.*[!@#$%^&*()_+\\-=\\[\\]{};':\"\\\\|,.<>/?]).{8,20}$"
    );

    private PasswordValidator() {
    }

    public static void validate(String password) {
        if (password == null || !PASSWORD_PATTERN.matcher(password).matches()) {
            throw new IllegalArgumentException(
                    "비밀번호는 영문, 숫자, 특수문자를 포함한 8~20자여야 합니다."
            );
        }
    }
}