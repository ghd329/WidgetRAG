package com.widgetrag.backend.product.dto;

public record UploadResponseDto(
        Long fileId,
        String fileName,
        String fileType,
        String status
) {}