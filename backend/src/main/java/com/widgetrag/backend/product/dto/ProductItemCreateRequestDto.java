package com.widgetrag.backend.product.dto;

public record ProductItemCreateRequestDto(
        String productName,
        int price,
        String category,
        String description
) {}