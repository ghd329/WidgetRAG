package com.widgetrag.backend.chat.dto;

import java.util.List;

public record ChatQueryResponseDto(
        String answer,
        List<RetrievedProductDto> recommendedProducts,
        boolean isFallback // 목업/Fallback 응답인지 여부 - 추후 실제 RAG 응답과 구분용
) {}