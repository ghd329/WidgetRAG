package com.widgetrag.backend.chat.dto;

public record RetrievedProductDto(
        Long productItemId,
        String productName,
        int price,
        String category
) {}