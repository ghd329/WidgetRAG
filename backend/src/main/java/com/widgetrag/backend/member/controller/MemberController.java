package com.widgetrag.backend.member.controller;

import com.widgetrag.backend.member.dto.*;
import com.widgetrag.backend.member.service.MemberService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/members")
@RequiredArgsConstructor
@Tag(name = "회원 관리", description = "회원가입, 합류, 로그인, 로그아웃 API")
public class MemberController {

    private final MemberService memberService;

    @Operation(summary = "신규 회원가입", description = "상점 이름, 이메일, 비밀번호를 입력하여 신규 회사(Company)와 첫 관리자 계정(Member)을 생성합니다. 가입 완료 시 시스템이 자동 생성한 상점 코드(client_code)를 응답으로 반환하며, 이 코드는 팀원이 같은 회사에 합류할 때 필요합니다.")
    @PostMapping("/signup")
    public ResponseEntity<SignupResponseDto> signup(@RequestBody SignupRequestDto request) {
        SignupResponseDto response = memberService.signup(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @Operation(summary = "기존 회사 합류", description = "이미 발급된 상점 코드(client_code)를 입력하여 기존 회사에 직원 계정으로 합류합니다. 존재하지 않는 상점 코드를 입력하면 400 에러가 반환됩니다.")
    @PostMapping("/join")
    public ResponseEntity<SignupResponseDto> join(@RequestBody JoinRequestDto request) {
        SignupResponseDto response = memberService.join(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @Operation(summary = "로그인", description = "이메일과 비밀번호로 로그인합니다. 인증에 성공하면 세션이 생성되며, 이후 요청에서 로그인 상태가 유지됩니다. 이메일/비밀번호가 일치하지 않으면 401 에러가 반환됩니다.")
    @PostMapping("/login")
    public ResponseEntity<LoginResponseDto> login(
            @RequestBody LoginRequestDto request,
            HttpServletRequest httpRequest
    ) {
        LoginResponseDto response = memberService.login(request);

        HttpSession session = httpRequest.getSession(true);
        session.setAttribute("memberId", response.memberId());
        session.setAttribute("clientCode", response.clientCode());
        session.setAttribute("companyId", response.companyId() );

        return ResponseEntity.ok(response);
    }

    @Operation(summary = "로그아웃", description = "현재 로그인된 세션을 무효화합니다. 별도의 회원 식별 정보 없이, 요청에 포함된 세션 쿠키를 기준으로 처리됩니다.")
    @PostMapping("/logout")
    public ResponseEntity<Void> logout(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        if (session != null) {
            session.invalidate();
        }
        return ResponseEntity.ok().build();
    }
}