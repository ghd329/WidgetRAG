package com.widgetrag.backend.product.exception;

public class TempFileNotFoundException extends RuntimeException {
    public TempFileNotFoundException(String token) {
        super("임시 파일을 찾을 수 없습니다. 다시 업로드해주세요: " + token);
    }
}