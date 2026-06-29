package com.widgetrag.backend.company.exception;

public class CompanyNameRequiredException extends RuntimeException {
    public CompanyNameRequiredException() {
        super("신규 상점 코드입니다. 상점 이름(companyName)을 입력해주세요.");
    }
}