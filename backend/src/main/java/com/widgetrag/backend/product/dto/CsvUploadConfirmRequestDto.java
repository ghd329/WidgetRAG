package com.widgetrag.backend.product.dto;

public record CsvUploadConfirmRequestDto(
        String tempFileToken,
        CsvMappingDto mapping,
        boolean saveAsDefault
) {}