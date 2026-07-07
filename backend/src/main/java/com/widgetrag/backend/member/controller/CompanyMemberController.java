package com.widgetrag.backend.member.controller;

import com.widgetrag.backend.member.dto.CompanyMemberResponseDto;
import com.widgetrag.backend.member.entity.Role;
import com.widgetrag.backend.member.exception.MemberAccessDeniedException;
import com.widgetrag.backend.member.service.CompanyMemberService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/company/members")
@RequiredArgsConstructor
@Tag(name = "기업 사원 승인 관리", description = "기업 대표가 자기 회사에 합류 신청한 사원을 승인/반려하는 API")
public class CompanyMemberController {

    private final CompanyMemberService companyMemberService;

    @Operation(summary = "합류 승인 대기 사원 목록 조회")
    @GetMapping("/pending")
    public ResponseEntity<List<CompanyMemberResponseDto>> getPendingMembers(HttpServletRequest httpRequest) {
        Long companyId = requireCompanyOwner(httpRequest);
        return ResponseEntity.ok(companyMemberService.getPendingMembers(companyId));
    }

    @Operation(summary = "사원 합류 승인")
    @PostMapping("/{memberId}/approve")
    public ResponseEntity<String> approveMember(@PathVariable Long memberId, HttpServletRequest httpRequest) {
        Long companyId = requireCompanyOwner(httpRequest);
        companyMemberService.approveMember(companyId, memberId);
        return ResponseEntity.ok("사원 승인 완료");
    }

    @Operation(summary = "사원 합류 반려")
    @PostMapping("/{memberId}/reject")
    public ResponseEntity<String> rejectMember(@PathVariable Long memberId, HttpServletRequest httpRequest) {
        Long companyId = requireCompanyOwner(httpRequest);
        companyMemberService.rejectMember(companyId, memberId);
        return ResponseEntity.ok("사원 반려 완료");
    }

    private Long requireCompanyOwner(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("companyId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }

        if (!Role.COMPANY_OWNER.name().equals(session.getAttribute("role"))) {
            throw new MemberAccessDeniedException();
        }

        return (Long) session.getAttribute("companyId");
    }
}
