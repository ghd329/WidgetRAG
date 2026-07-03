package com.widgetrag.backend.member.controller;

import com.widgetrag.backend.member.dto.AdminMemberResponseDto;
import com.widgetrag.backend.member.service.AdminMemberService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/admin/members")
@RequiredArgsConstructor
public class AdminMemberController {

    private final AdminMemberService adminMemberService;

    @GetMapping
    public ResponseEntity<List<AdminMemberResponseDto>> getMembers() {
        return ResponseEntity.ok(adminMemberService.getMembers());
    }

    @DeleteMapping("/{memberId}")
    public ResponseEntity<String> deleteMember(@PathVariable Long memberId) {
        adminMemberService.deleteMember(memberId);
        return ResponseEntity.ok("회원 탈퇴 처리 완료");
    }
}

