package com.widgetrag.backend.company.exception;

public class CompanyNotFoundException extends RuntimeException {
    public CompanyNotFoundException(String clientCode) {
        super("존재하지 않는 상점 코드입니다: " + clientCode);
    }
}