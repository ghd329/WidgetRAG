package com.widgetrag.backend.product.exception;

public class ProductNotFoundException extends RuntimeException {
    public ProductNotFoundException(Long fileId) {
        super("존재하지 않는 상품 파일입니다: " + fileId);
    }
}