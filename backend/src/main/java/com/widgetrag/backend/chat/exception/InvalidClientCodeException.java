package com.widgetrag.backend.chat.exception;

public class InvalidClientCodeException extends RuntimeException {
    public InvalidClientCodeException(String clientCode) {
        super("유효하지 않은 상점 코드입니다: " + clientCode);
    }
}