package com.widgetrag.backend.product.dto;

public record IncrementalUploadResultDto(
        int created,
        int updated,
        int skipped
) {}