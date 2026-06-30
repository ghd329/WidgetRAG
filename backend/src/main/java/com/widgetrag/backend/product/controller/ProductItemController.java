package com.widgetrag.backend.product.controller;

import com.widgetrag.backend.product.dto.ProductItemCreateRequestDto;
import com.widgetrag.backend.product.dto.ProductItemResponseDto;
import com.widgetrag.backend.product.service.ProductItemService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/product-items")
@RequiredArgsConstructor
@Tag(name = "개별 상품 관리", description = "CSV 업로드로 생성되거나 화면에서 직접 추가한 개별 상품 CRUD")
public class ProductItemController {

    private final ProductItemService productItemService;

    @Operation(summary = "개별 상품 목록 조회")
    @GetMapping
    public ResponseEntity<List<ProductItemResponseDto>> list(HttpServletRequest httpRequest) {
        Long companyId = requireCompanyId(httpRequest);
        return ResponseEntity.ok(productItemService.getList(companyId));
    }

    @Operation(summary = "쇼핑몰 공개 상품 목록 조회", description = "clientCode로 로그인 없이 상품 목록을 조회합니다.")
    @GetMapping("/public/{clientCode}")
    public ResponseEntity<List<ProductItemResponseDto>> listPublic(@PathVariable String clientCode) {
        return ResponseEntity.ok(productItemService.getListByClientCode(clientCode));
    }

    @Operation(summary = "개별 상품 추가", description = "화면에서 직접 상품 하나를 추가합니다.")
    @PostMapping
    public ResponseEntity<ProductItemResponseDto> create(
            @RequestBody ProductItemCreateRequestDto request, HttpServletRequest httpRequest) {
        Long companyId = requireCompanyId(httpRequest);
        Long memberId = requireMemberId(httpRequest);
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(productItemService.create(request, companyId, memberId));
    }

    @Operation(summary = "개별 상품 수정")
    @PutMapping("/{itemId}")
    public ResponseEntity<ProductItemResponseDto> update(
            @PathVariable Long itemId,
            @RequestBody ProductItemCreateRequestDto request, HttpServletRequest httpRequest) {
        Long companyId = requireCompanyId(httpRequest);
        Long memberId = requireMemberId(httpRequest);
        return ResponseEntity.ok(productItemService.update(itemId, request, companyId, memberId));
    }

    @Operation(summary = "개별 상품 삭제")
    @DeleteMapping("/{itemId}")
    public ResponseEntity<Void> delete(@PathVariable Long itemId, HttpServletRequest httpRequest) {
        Long companyId = requireCompanyId(httpRequest);
        Long memberId = requireMemberId(httpRequest);
        productItemService.delete(itemId, companyId, memberId);
        return ResponseEntity.noContent().build();
    }

    private Long requireCompanyId(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("companyId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }
        return (Long) session.getAttribute("companyId");
    }

    private Long requireMemberId(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        return (Long) session.getAttribute("memberId");
    }
}