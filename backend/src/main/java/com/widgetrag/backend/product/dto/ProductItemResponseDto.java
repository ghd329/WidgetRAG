package com.widgetrag.backend.product.dto;

import java.time.LocalDateTime;
import java.util.List;

public record ProductItemResponseDto(
        Long id,
        String productName,
        int price,
        List<String> categories, // 단일 → 리스트로 변경
        String description,
        String productUrl,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {}