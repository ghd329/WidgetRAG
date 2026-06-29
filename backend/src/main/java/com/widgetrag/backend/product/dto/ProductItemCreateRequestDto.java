package com.widgetrag.backend.product.dto;

import java.util.List;

public record ProductItemCreateRequestDto(
        String productName,
        int price,
        List<String> categories, // 단일 → 리스트로 변경
        String description
) {}