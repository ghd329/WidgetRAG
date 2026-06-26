package com.widgetrag.backend.product.dto;

import java.time.LocalDateTime;

public record ProductItemResponseDto(
        Long id,
        String productName,
        int price,
        String category,
        String description,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {}