package com.widgetrag.backend.product.exception;

public class InvalidFileFormatException extends RuntimeException {
    public InvalidFileFormatException(String fileName) {
        super("지원하지 않는 파일 형식입니다: " + fileName + " (txt, csv만 허용)");
    }
}