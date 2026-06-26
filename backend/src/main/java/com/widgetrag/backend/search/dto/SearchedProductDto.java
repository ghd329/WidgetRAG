package com.widgetrag.backend.search.dto;

import java.util.List;

public record SearchedProductDto(
        Long productItemId,
        String productName,
        int price,
        List<String> categories
) {}