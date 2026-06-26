package com.widgetrag.backend.product.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import com.widgetrag.backend.product.dto.ProductItemCreateRequestDto;
import com.widgetrag.backend.product.dto.ProductItemResponseDto;
import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.entity.ProductItem;
import com.widgetrag.backend.product.exception.ProductAccessDeniedException;
import com.widgetrag.backend.product.exception.ProductItemNotFoundException;
import com.widgetrag.backend.product.repository.ProductItemRepository;
import lombok.RequiredArgsConstructor;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.IOException;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

@Service
@RequiredArgsConstructor
public class ProductItemService {

    private final ProductItemRepository productItemRepository;
    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository; // 추가됨

    @Transactional
    public void parseAndSaveFromCsv(Path csvPath, Company company, Product sourceFile, Member uploader) {
        try (Reader reader = Files.newBufferedReader(csvPath, StandardCharsets.UTF_8)) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.builder()
                    .setHeader()
                    .setSkipHeaderRecord(true)
                    .build()
                    .parse(reader);

            for (CSVRecord record : records) {
                String productName = record.get("product_name");
                int price = Integer.parseInt(record.get("price").trim());
                String category = record.isMapped("category") ? record.get("category") : null;
                String description = record.isMapped("description") ? record.get("description") : null;

                ProductItem item = ProductItem.createFromFile(
                        company, sourceFile, uploader, productName, price, category, description);
                productItemRepository.save(item);
            }
        } catch (IOException e) {
            throw new RuntimeException("CSV 파싱 중 오류가 발생했습니다.", e);
        }
    }

    @Transactional(readOnly = true)
    public List<ProductItemResponseDto> getList(Long companyId) {
        return productItemRepository.findByCompanyIdAndDeletedAtIsNull(companyId)
                .stream()
                .map(this::toDto)
                .toList();
    }

    @Transactional
    public ProductItemResponseDto create(ProductItemCreateRequestDto request, Long companyId, Long memberId) {
        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalStateException("회사 정보를 찾을 수 없습니다."));
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        ProductItem item = ProductItem.createManually(
                company, member, request.productName(), request.price(), request.category(), request.description());
        productItemRepository.save(item);
        return toDto(item);
    }

    @Transactional
    public ProductItemResponseDto update(Long itemId, ProductItemCreateRequestDto request, Long companyId, Long memberId) {
        ProductItem item = productItemRepository.findByIdAndDeletedAtIsNull(itemId)
                .orElseThrow(() -> new ProductItemNotFoundException(itemId));

        if (!item.getCompany().getId().equals(companyId)) {
            throw new ProductAccessDeniedException();
        }

        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        item.update(request.productName(), request.price(), request.category(), request.description(), member);
        return toDto(item);
    }

    @Transactional
    public void delete(Long itemId, Long companyId, Long memberId) {
        ProductItem item = productItemRepository.findByIdAndDeletedAtIsNull(itemId)
                .orElseThrow(() -> new ProductItemNotFoundException(itemId));

        if (!item.getCompany().getId().equals(companyId)) {
            throw new ProductAccessDeniedException();
        }

        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        item.markAsDeleted(member);
    }

    private ProductItemResponseDto toDto(ProductItem item) {
        return new ProductItemResponseDto(
                item.getId(), item.getProductName(), item.getPrice(),
                item.getCategory(), item.getDescription(), item.getCreatedAt(), item.getUpdatedAt()
        );
    }
}