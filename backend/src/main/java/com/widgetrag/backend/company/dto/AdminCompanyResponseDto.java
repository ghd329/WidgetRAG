package com.widgetrag.backend.company.dto;

import com.widgetrag.backend.company.entity.CompanyStatus;

public record AdminCompanyResponseDto(
        Long companyId,
        String companyName,
        String clientCode,
        String ownerEmail,
        String ownerName,
        CompanyStatus status
) {
}