package com.widgetrag.backend.product.controller;

import com.widgetrag.backend.product.dto.UploadResponseDto;
import com.widgetrag.backend.product.service.FileStorageService;
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
public class ProductController {

    private final FileStorageService fileStorageService;

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