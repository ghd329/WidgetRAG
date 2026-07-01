package com.widgetrag.backend.chat.dto;

import java.time.LocalDateTime;

public record ChatLogResponseDto(
        Long id,
        String question,
        String answer,
        boolean isFallback,
        LocalDateTime createdAt
) {}