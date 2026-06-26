package com.widgetrag.backend.chat.dto;

public record ChatQueryRequestDto(
        String clientCode,
        String question
) {}