package com.widgetrag.backend.product.exception;

public class ProductAccessDeniedException extends RuntimeException {
    public ProductAccessDeniedException() {
        super("해당 파일에 접근할 권한이 없습니다.");
    }
}