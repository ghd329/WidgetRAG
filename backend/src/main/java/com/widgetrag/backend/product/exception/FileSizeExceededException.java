package com.widgetrag.backend.product.exception;

public class FileSizeExceededException extends RuntimeException {
    public FileSizeExceededException(long actualSize, long maxSize) {
        super(String.format("파일 용량이 초과되었습니다. (업로드: %dMB, 제한: %dMB)",
                actualSize / 1024 / 1024, maxSize / 1024 / 1024));
    }
}