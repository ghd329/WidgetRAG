package com.widgetrag.backend.company.repository;

import com.widgetrag.backend.company.entity.Company;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface CompanyRepository extends JpaRepository<Company, Long> {

    Optional<Company> findByClientCode(String clientCode);

    boolean existsByClientCode(String clientCode);
}