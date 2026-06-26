package com.widgetrag.backend.product.controller;

import com.widgetrag.backend.product.dto.UploadResponseDto;
import com.widgetrag.backend.product.service.FileStorageService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/products")
@RequiredArgsConstructor
@Tag(name = "상품 데이터 관리", description = "상품 데이터 파일(.txt/.csv) 업로드 API")
public class ProductController {

    private final FileStorageService fileStorageService;

    @Operation(summary = "상품 데이터 파일 업로드", description = "로그인한 회원이 소속된 회사의 상품 데이터 파일(.txt 또는 .csv)을 업로드합니다. 파일은 WSL 환경 내 회사 코드(client_code)별로 격리된 경로에 저장되며, 최대 50MB까지 허용됩니다. 로그인하지 않은 경우 401, 지원하지 않는 형식이거나 용량을 초과하면 400 에러가 반환됩니다.")
    @PostMapping("/upload")
    public ResponseEntity<UploadResponseDto> upload(
            @RequestParam("file") MultipartFile file,
            HttpServletRequest httpRequest
    ) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("memberId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }

        Long memberId = (Long) session.getAttribute("memberId");
        Long companyId = (Long) session.getAttribute("companyId");

        UploadResponseDto response = fileStorageService.upload(file, companyId, memberId);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }
}