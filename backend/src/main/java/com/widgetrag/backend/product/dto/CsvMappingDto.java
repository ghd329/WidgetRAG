package com.widgetrag.backend.product.dto;

public record CsvMappingDto(
        String productIdColumn,
        String productNameColumn,
        String priceColumn,
        String categoryColumn,
        String descriptionColumn
) {}