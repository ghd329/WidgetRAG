package com.widgetrag.backend.product.dto;

import java.util.List;
import java.util.Map;

public record CsvPreviewResponseDto(
        String tempFileToken, // 임시로 저장한 파일을 다시 찾기 위한 토큰
        List<String> headers,
        List<Map<String, String>> sampleRows, // 미리보기용 샘플 2~3줄
        CsvMappingDto suggestedMapping, // 시스템이 추측한 기본 매핑
        boolean hasSavedMapping // 이미 저장된 매핑이 있는지
) {}