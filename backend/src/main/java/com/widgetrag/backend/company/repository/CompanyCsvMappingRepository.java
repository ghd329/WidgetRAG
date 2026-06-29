package com.widgetrag.backend.company.repository;

import com.widgetrag.backend.company.entity.CompanyCsvMapping;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface CompanyCsvMappingRepository extends JpaRepository<CompanyCsvMapping, Long> {
    Optional<CompanyCsvMapping> findByCompanyId(Long companyId);
}