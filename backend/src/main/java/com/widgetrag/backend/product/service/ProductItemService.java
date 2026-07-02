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
    private final OpenSearchIndexService openSearchIndexService;

    /**
     * CSV를 파싱하여 상품을 저장하고, 행 단위로 CSV 파싱/DB 저장 구간과
     * 임베딩/OpenSearch 색인 구간의 소요 시간을 측정하여 로그로 출력한다.
     * (성능 병목 확인용 임시 계측 코드 - 확인 후 제거 또는 로거로 전환 예정)
     */
    @Transactional
    public IncrementalUploadResultDto parseAndSaveFromCsv(Path csvPath, Company company, Product sourceFile,
                                                          Member uploader, CsvMappingDto mapping) {
        int created = 0;
        int updated = 0;
        int skipped = 0;
        int rowCount = 0;

        long parseAndSaveTimeMs = 0; // CSV 파싱 + DB 저장 누적 시간
        long indexTimeMs = 0;        // 임베딩 + OpenSearch 색인 누적 시간
        long totalStart = System.currentTimeMillis();

        Map<String, ProductItem> processedInThisBatch = new HashMap<>();

        try (Reader reader = createBomAwareReader(csvPath)) {
            Iterable<CSVRecord> records = CSVFormat.DEFAULT.builder()
                    .setHeader()
                    .setSkipHeaderRecord(true)
                    .setTrim(true)
                    .build()
                    .parse(reader);

            for (CSVRecord record : records) {
                rowCount++;
                long rowStart = System.currentTimeMillis();

                String externalId  = readColumn(record, mapping.productIdColumn());
                String productName = readColumn(record, mapping.productNameColumn());
                String priceRaw    = readColumn(record, mapping.priceColumn());
                int price = priceRaw == null ? 0 : Integer.parseInt(priceRaw.trim().replaceAll("[^0-9]", ""));
                String category    = readColumn(record, mapping.categoryColumn());
                String description = readColumn(record, mapping.descriptionColumn());
                String productUrl  = readColumn(record, mapping.urlColumn());

                if (externalId == null || externalId.isBlank()) {
                    ProductItem item = ProductItem.createFromFile(
                            company, sourceFile, uploader, null, productName, price, description, productUrl);
                    if (!isMeaningless(category)) item.addCategory(category);
                    productItemRepository.save(item);

                    long afterSave = System.currentTimeMillis();
                    parseAndSaveTimeMs += (afterSave - rowStart);

                    openSearchIndexService.indexProductItem(item);
                    indexTimeMs += (System.currentTimeMillis() - afterSave);

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

                        if (item.hasDifferentContent(productName, price, description, productUrl)) {
                            item.update(productName, price, description, productUrl, uploader);
                            updated++;
                        } else {
                            skipped++;
                        }

                        long afterSave = System.currentTimeMillis();
                        parseAndSaveTimeMs += (afterSave - rowStart);

                        openSearchIndexService.indexProductItem(item);
                        indexTimeMs += (System.currentTimeMillis() - afterSave);
                    } else {
                        item = ProductItem.createFromFile(
                                company, sourceFile, uploader, externalId, productName, price, description, productUrl);
                        if (!isMeaningless(category)) item.addCategory(category);
                        productItemRepository.save(item);

                        long afterSave = System.currentTimeMillis();
                        parseAndSaveTimeMs += (afterSave - rowStart);

                        openSearchIndexService.indexProductItem(item);
                        indexTimeMs += (System.currentTimeMillis() - afterSave);

                        created++;
                    }

                    processedInThisBatch.put(externalId, item);

                } else {
                    if (!isMeaningless(category)) {
                        item.addCategory(category);

                        long afterSave = System.currentTimeMillis();
                        parseAndSaveTimeMs += (afterSave - rowStart);

                        openSearchIndexService.indexProductItem(item);
                        indexTimeMs += (System.currentTimeMillis() - afterSave);
                    } else {
                        parseAndSaveTimeMs += (System.currentTimeMillis() - rowStart);
                    }
                    skipped++;
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("CSV 파싱 중 오류가 발생했습니다.", e);
        }

        long totalTimeMs = System.currentTimeMillis() - totalStart;
        System.out.println("========== 업로드 소요시간 분석 ==========");
        System.out.println("총 처리 행 수            : " + rowCount + "건");
        System.out.println("CSV 파싱 + DB 저장 총합   : " + parseAndSaveTimeMs + "ms");
        System.out.println("임베딩 + OpenSearch 색인 총합 : " + indexTimeMs + "ms");
        System.out.println("전체 소요 시간            : " + totalTimeMs + "ms");
        System.out.println("생성 " + created + "건 / 수정 " + updated + "건 / 스킵 " + skipped + "건");
        System.out.println("==========================================");

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

    @Transactional(readOnly = true)
    public List<ProductItemResponseDto> getListByClientCode(String clientCode) {
        return productItemRepository.findByCompanyClientCodeAndDeletedAtIsNull(clientCode)
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
        openSearchIndexService.indexProductItem(item);
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

        // request에 url이 없으면 기존 url 유지
        String productUrl = request.productUrl() != null ? request.productUrl() : item.getProductUrl();
        item.update(request.productName(), request.price(), request.description(), productUrl, member);
        if (request.categories() != null) {
            request.categories().forEach(item::addCategory);
        }
        openSearchIndexService.indexProductItem(item);
        return toDto(item);
    }

    @Transactional
    public void deleteByProduct(Product product, Member member) {
        List<ProductItem> items = productItemRepository.findBySourceFileAndDeletedAtIsNull(product);
        for (ProductItem item : items) {
            item.markAsDeleted(member);
            openSearchIndexService.deleteProductItem(item.getId());
        }
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
        openSearchIndexService.deleteProductItem(item.getId());
    }

    private ProductItemResponseDto toDto(ProductItem item) {
        return new ProductItemResponseDto(
                item.getId(), item.getProductName(), item.getPrice(),
                item.getCategoryNames(), item.getDescription(),
                item.getProductUrl(),
                item.getCreatedAt(), item.getUpdatedAt()
        );
    }
}