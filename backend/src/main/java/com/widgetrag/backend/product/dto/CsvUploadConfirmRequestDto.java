package com.widgetrag.backend.product.dto;

public record CsvUploadConfirmRequestDto(
        String tempFileToken,
        String originalFilename,
        CsvMappingDto mapping,
        boolean saveAsDefault
) {
}