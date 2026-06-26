package com.widgetrag.backend.product.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import com.widgetrag.backend.product.dto.CsvMappingDto;
import com.widgetrag.backend.product.dto.IncrementalUploadResultDto;
import com.widgetrag.backend.product.dto.ProductItemCreateRequestDto;
import com.widgetrag.backend.product.dto.ProductItemResponseDto;
import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.entity.ProductItem;
import com.widgetrag.backend.product.exception.ProductAccessDeniedException;
import com.widgetrag.backend.product.exception.ProductItemNotFoundException;
import com.widgetrag.backend.product.repository.ProductItemRepository;
import com.widgetrag.backend.search.service.OpenSearchIndexService;
import lombok.RequiredArgsConstructor;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class ProductItemService {

    private static final Set<String> MEANINGLESS_CATEGORIES = Set.of("전체", "ALL", "all", "");

    private final ProductItemRepository productItemRepository;
    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final OpenSearchIndexService openSearchIndexService; // 추가

    // CSV 업로드 시 호출 - 매핑 정보 기준으로 파싱, 같은 배치 내 중복 product_id도 안전하게 처리
    @Transactional
    public IncrementalUploadResultDto parseAndSaveFromCsv(Path csvPath, Company company, Product sourceFile,
                                                          Member uploader, CsvMappingDto mapping) {

        int created = 0;
        int updated = 0;
        int skipped = 0;

        Map<String, ProductItem> processedInThisBatch = new HashMap<>();

        try (Reader reader = createBomAwareReader(csvPath)) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.builder()
                    .setHeader()
                    .setSkipHeaderRecord(true)
                    .setTrim(true)
                    .build()
                    .parse(reader);

            for (CSVRecord record : records) {
                String externalId = readColumn(record, mapping.productIdColumn());
                String productName = readColumn(record, mapping.productNameColumn());
                String priceRaw = readColumn(record, mapping.priceColumn());
                int price = priceRaw == null ? 0 : Integer.parseInt(priceRaw.trim().replaceAll("[^0-9]", ""));
                String category = readColumn(record, mapping.categoryColumn());
                String description = readColumn(record, mapping.descriptionColumn());

                if (externalId == null || externalId.isBlank()) {
                    ProductItem item = ProductItem.createFromFile(
                            company, sourceFile, uploader, null, productName, price, description);
                    if (!isMeaningless(category)) item.addCategory(category);
                    productItemRepository.save(item);
                    openSearchIndexService.indexProductItem(item); // 추가
                    created++;
                    continue;
                }

                ProductItem item = processedInThisBatch.get(externalId);

                if (item == null) {
                    Optional<ProductItem> existing = productItemRepository
                            .findByCompanyIdAndExternalProductIdAndDeletedAtIsNull(company.getId(), externalId);

                    if (existing.isPresent()) {
                        item = existing.get();
                        if (!isMeaningless(category)) item.addCategory(category);

                        if (item.hasDifferentContent(productName, price, description)) {
                            item.update(productName, price, description, uploader);
                            updated++;
                        } else {
                            skipped++;
                        }
                        openSearchIndexService.indexProductItem(item); // 추가 - 카테고리만 추가돼도 색인 갱신 필요
                    } else {
                        item = ProductItem.createFromFile(
                                company, sourceFile, uploader, externalId, productName, price, description);
                        if (!isMeaningless(category)) item.addCategory(category);
                        productItemRepository.save(item);
                        openSearchIndexService.indexProductItem(item); // 추가
                        created++;
                    }

                    processedInThisBatch.put(externalId, item);

                } else {
                    if (!isMeaningless(category)) {
                        item.addCategory(category);
                        openSearchIndexService.indexProductItem(item); // 추가 - 카테고리 추가분 반영
                    }
                    skipped++;
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("CSV 파싱 중 오류가 발생했습니다.", e);
        }

        return new IncrementalUploadResultDto(created, updated, skipped);
    }

    private String readColumn(CSVRecord record, String columnName) {
        if (columnName == null || !record.isMapped(columnName)) return null;
        return record.get(columnName);
    }

    private boolean isMeaningless(String category) {
        return category == null || MEANINGLESS_CATEGORIES.contains(category.trim());
    }

    private Reader createBomAwareReader(Path csvPath) throws IOException {
        byte[] bytes = Files.readAllBytes(csvPath);
        int offset = 0;
        if (bytes.length >= 3 && bytes[0] == (byte) 0xEF && bytes[1] == (byte) 0xBB && bytes[2] == (byte) 0xBF) {
            offset = 3;
        }
        return new InputStreamReader(
                new ByteArrayInputStream(bytes, offset, bytes.length - offset),
                StandardCharsets.UTF_8);
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
                company, member, request.productName(), request.price(), request.description());
        if (request.categories() != null) {
            request.categories().forEach(item::addCategory);
        }
        productItemRepository.save(item);
        openSearchIndexService.indexProductItem(item); // 추가
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

        item.update(request.productName(), request.price(), request.description(), member);
        if (request.categories() != null) {
            request.categories().forEach(item::addCategory);
        }
        openSearchIndexService.indexProductItem(item); // 추가
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
        openSearchIndexService.deleteProductItem(item.getId()); // 추가
    }

    private ProductItemResponseDto toDto(ProductItem item) {
        return new ProductItemResponseDto(
                item.getId(), item.getProductName(), item.getPrice(),
                item.getCategoryNames(), item.getDescription(), item.getCreatedAt(), item.getUpdatedAt()
        );
    }
}