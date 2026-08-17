package com.widgetrag.backend.company.controller;

import com.widgetrag.backend.company.dto.AdminCompanyResponseDto;
import com.widgetrag.backend.company.service.AdminCompanyService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/admin/companies")
@RequiredArgsConstructor
public class AdminCompanyController {

    private final AdminCompanyService adminCompanyService;

    /**
     * 전체 기업 목록(시스템 회사 제외). 관리자 화면이 상태별 건수를 집계하는 데 사용합니다.
     */
    @GetMapping
    public ResponseEntity<List<AdminCompanyResponseDto>> getCompanies() {
        return ResponseEntity.ok(adminCompanyService.getCompanies());
    }

    @GetMapping("/pending")
    public ResponseEntity<List<AdminCompanyResponseDto>> getPendingCompanies() {
        return ResponseEntity.ok(adminCompanyService.getPendingCompanies());
    }

    @PostMapping("/{companyId}/approve")
    public ResponseEntity<String> approveCompany(@PathVariable Long companyId) {
        adminCompanyService.approveCompany(companyId);
        return ResponseEntity.ok("기업 승인 완료");
    }

    @PostMapping("/{companyId}/reject")
    public ResponseEntity<String> rejectCompany(@PathVariable Long companyId) {
        adminCompanyService.rejectCompany(companyId);
        return ResponseEntity.ok("기업 반려 완료");
    }

    @DeleteMapping("/{companyId}")
    public ResponseEntity<String> deleteCompany(@PathVariable Long companyId) {
        adminCompanyService.deleteCompany(companyId);
        return ResponseEntity.ok("기업 탈퇴 처리 완료");
    }
}