package com.widgetrag.backend.company.controller;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.entity.CompanyStatus;
import com.widgetrag.backend.company.repository.CompanyRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/companies")
@RequiredArgsConstructor
public class CompanyController {

    private final CompanyRepository companyRepository;

    @GetMapping("/approved")
    public ResponseEntity<List<Company>> getApprovedCompanies() {
        return ResponseEntity.ok(
                companyRepository.findByStatus(CompanyStatus.APPROVED)
        );
    }
}