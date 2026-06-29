package com.widgetrag.backend.product.exception;

public class ProductItemNotFoundException extends RuntimeException {
    public ProductItemNotFoundException(Long id) {
        super("존재하지 않는 상품입니다: " + id);
    }
}