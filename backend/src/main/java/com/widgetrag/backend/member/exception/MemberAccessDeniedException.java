package com.widgetrag.backend.member.exception;

public class MemberAccessDeniedException extends RuntimeException {
    public MemberAccessDeniedException() {
        super("해당 회원에 대한 권한이 없습니다.");
    }
}
