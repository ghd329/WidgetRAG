package com.widgetrag.backend.product.dto;

import java.time.LocalDateTime;

public record ProductListItemDto(
        Long fileId,
        String fileName,
        String fileType,
        String status,
        LocalDateTime uploadedAt,
        LocalDateTime updatedAt
) {}