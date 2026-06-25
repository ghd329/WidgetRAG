package com.widgetrag.backend.member.controller;

import com.widgetrag.backend.member.dto.SignupRequestDto;
import com.widgetrag.backend.member.dto.SignupResponseDto;
import com.widgetrag.backend.member.service.MemberService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/members")
@RequiredArgsConstructor
public class MemberController {

    private final MemberService memberService;

    @PostMapping("/signup")
    public ResponseEntity<SignupResponseDto> signup(@RequestBody SignupRequestDto request) {
        SignupResponseDto response = memberService.signup(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }
}