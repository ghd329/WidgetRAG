package com.widgetrag.backend.product.controller;

import com.widgetrag.backend.product.dto.ProductListItemDto;
import com.widgetrag.backend.product.dto.UploadResponseDto;
import com.widgetrag.backend.product.service.FileStorageService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.util.List;

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

    @Operation(summary = "상품 파일 목록 조회", description = "로그인한 회원이 소속된 회사의 업로드된 상품 파일 목록을 조회합니다. 삭제된 파일은 제외됩니다.")
    @GetMapping
    public ResponseEntity<List<ProductListItemDto>> list(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("companyId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }
        Long companyId = (Long) session.getAttribute("companyId");
        return ResponseEntity.ok(fileStorageService.getProductList(companyId));
    }

    @Operation(summary = "상품 파일 수정", description = "기존에 업로드된 상품 파일을 새 파일로 교체합니다. 다른 회사 소속 파일은 수정할 수 없습니다.")
    @PutMapping("/{fileId}")
    public ResponseEntity<UploadResponseDto> update(
            @PathVariable Long fileId,
            @RequestParam("file") MultipartFile file,
            HttpServletRequest httpRequest
    ) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("memberId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }
        Long memberId = (Long) session.getAttribute("memberId");
        Long companyId = (Long) session.getAttribute("companyId");

        UploadResponseDto response = fileStorageService.update(fileId, file, companyId, memberId);
        return ResponseEntity.ok(response);
    }

    @Operation(summary = "상품 파일 삭제", description = "업로드된 상품 파일을 삭제합니다. WSL의 실제 파일은 즉시 삭제되며, DB에는 삭제 기록(soft delete)이 유지됩니다.")
    @DeleteMapping("/{fileId}")
    public ResponseEntity<Void> delete(
            @PathVariable Long fileId,
            HttpServletRequest httpRequest
    ) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("memberId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }
        Long memberId = (Long) session.getAttribute("memberId");
        Long companyId = (Long) session.getAttribute("companyId");

        fileStorageService.delete(fileId, companyId, memberId);
        return ResponseEntity.noContent().build();
    }
}