package com.widgetrag.backend.product.dto;

import java.time.LocalDateTime;

public record UploadResponseDto(
        Long fileId,
        String fileName,
        String fileType,
        LocalDateTime uploadedAt,
        String status,
        int createdCount,
        int updatedCount,
        int duplicateCount
) {
}