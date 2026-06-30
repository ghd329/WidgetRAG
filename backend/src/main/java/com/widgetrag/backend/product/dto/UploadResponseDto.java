package com.widgetrag.backend.product.dto;

public record UploadResponseDto(
        Long fileId,
        String fileName,
        String fileType,
        String status,
        IncrementalUploadResultDto itemResult // 추가 - null 가능 (txt는 파싱 안 하니까)
) {}