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

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PushbackInputStream;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class ProductItemService {

    private static final Set<String> MEANINGLESS_CATEGORIES = Set.of("전체", "ALL", "all", "");
    private static final int EXISTING_ITEM_LOOKUP_BATCH_SIZE = 1000;

    private final ProductItemRepository productItemRepository;
    private final MemberRepository memberRepository;
    private final CompanyRepository companyRepository;
    private final OpenSearchIndexService openSearchIndexService;

    private record CsvProductRow(String externalId, String productName, int price,
                                 String category, String description, String productUrl) {
    }

    /**
     * CSV를 파싱하여 상품을 배치 저장/색인한다.
     * 각 단계(CSV 파싱, 기존 상품 조회, DB 저장, OpenSearch 색인)의 소요 시간을
     * 로그로 출력한다. (성능 확인용 임시 계측 코드 - 확인 후 제거 예정)
     */
    @Transactional
    public IncrementalUploadResultDto parseAndSaveFromCsv(Path csvPath, Company company, Product sourceFile,
                                                          Member uploader, CsvMappingDto mapping) {
        int created = 0;
        int updated = 0;
        int skipped = 0;

        long totalStart = System.currentTimeMillis();

        List<CsvProductRow> rows = new ArrayList<>();
        Set<String> externalIds = new LinkedHashSet<>();

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
                int price = parsePrice(readColumn(record, mapping.priceColumn()));
                String category = readColumn(record, mapping.categoryColumn());
                String description = readColumn(record, mapping.descriptionColumn());
                String productUrl = readColumn(record, mapping.urlColumn());

                rows.add(new CsvProductRow(externalId, productName, price, category, description, productUrl));
                if (externalId != null && !externalId.isBlank()) {
                    externalIds.add(externalId);
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("CSV parsing failed.", e);
        }

        long afterParse = System.currentTimeMillis();

        Map<String, ProductItem> existingItems = findExistingItems(company.getId(), externalIds);

        long afterLookup = System.currentTimeMillis();

        Map<String, ProductItem> processedInThisBatch = new HashMap<>();
        List<ProductItem> itemsToSave = new ArrayList<>();
        Set<ProductItem> itemsToIndex = new LinkedHashSet<>();

        for (CsvProductRow row : rows) {
            if (row.externalId() == null || row.externalId().isBlank()) {
                ProductItem item = ProductItem.createFromFile(
                        company, sourceFile, uploader, null, row.productName(), row.price(),
                        row.description(), row.productUrl());
                if (!isMeaningless(row.category())) item.addCategory(row.category());
                itemsToSave.add(item);
                itemsToIndex.add(item);
                created++;
                continue;
            }

            ProductItem item = processedInThisBatch.get(row.externalId());

            if (item == null) {
                item = existingItems.get(row.externalId());

                if (item != null) {
                    boolean changed = false;
                    if (!isMeaningless(row.category())) {
                        changed = item.addCategory(row.category());
                    }

                    if (item.hasDifferentContent(row.productName(), row.price(), row.description(), row.productUrl())) {
                        item.update(row.productName(), row.price(), row.description(), row.productUrl(), uploader);
                        changed = true;
                        updated++;
                    } else {
                        skipped++;
                    }

                    if (changed) {
                        itemsToSave.add(item);
                        itemsToIndex.add(item);
                    }
                } else {
                    item = ProductItem.createFromFile(
                            company, sourceFile, uploader, row.externalId(), row.productName(), row.price(),
                            row.description(), row.productUrl());
                    if (!isMeaningless(row.category())) item.addCategory(row.category());
                    itemsToSave.add(item);
                    itemsToIndex.add(item);
                    created++;
                }

                processedInThisBatch.put(row.externalId(), item);
            } else {
                if (!isMeaningless(row.category()) && item.addCategory(row.category())) {
                    itemsToSave.add(item);
                    itemsToIndex.add(item);
                }
                skipped++;
            }
        }

        long afterMerge = System.currentTimeMillis();

        if (!itemsToSave.isEmpty()) {
            productItemRepository.saveAllAndFlush(itemsToSave);
        }

        long afterDbSave = System.currentTimeMillis();

        openSearchIndexService.indexProductItems(new ArrayList<>(itemsToIndex));

        long afterIndex = System.currentTimeMillis();

        System.out.println("========== 업로드 소요시간 분석 ==========");
        System.out.println("총 CSV 행 수              : " + rows.size() + "건");
        System.out.println("색인 대상 건수             : " + itemsToIndex.size() + "건");
        System.out.println("CSV 파싱                  : " + (afterParse - totalStart) + "ms");
        System.out.println("기존 상품 조회(DB)         : " + (afterLookup - afterParse) + "ms");
        System.out.println("병합/비교 로직             : " + (afterMerge - afterLookup) + "ms");
        System.out.println("DB 저장(saveAllAndFlush)   : " + (afterDbSave - afterMerge) + "ms");
        System.out.println("임베딩 + OpenSearch 배치 색인 : " + (afterIndex - afterDbSave) + "ms");
        System.out.println("전체 소요 시간             : " + (afterIndex - totalStart) + "ms");
        System.out.println("생성 " + created + "건 / 수정 " + updated + "건 / 스킵 " + skipped + "건");
        System.out.println("==========================================");

        return new IncrementalUploadResultDto(created, updated, skipped);
    }

    private Map<String, ProductItem> findExistingItems(Long companyId, Set<String> externalIds) {
        if (externalIds.isEmpty()) return Map.of();

        List<ProductItem> items = partition(externalIds, EXISTING_ITEM_LOOKUP_BATCH_SIZE).stream()
                .flatMap(batch -> productItemRepository
                        .findByCompanyIdAndExternalProductIdInAndDeletedAtIsNull(companyId, batch)
                        .stream())
                .toList();

        return items.stream()
                .collect(Collectors.toMap(ProductItem::getExternalProductId, item -> item, (left, right) -> left));
    }

    private List<List<String>> partition(Collection<String> values, int batchSize) {
        List<String> list = new ArrayList<>(values);
        List<List<String>> batches = new ArrayList<>();
        for (int i = 0; i < list.size(); i += batchSize) {
            batches.add(list.subList(i, Math.min(i + batchSize, list.size())));
        }
        return batches;
    }

    private String readColumn(CSVRecord record, String columnName) {
        if (columnName == null || !record.isMapped(columnName)) return null;
        return record.get(columnName);
    }

    private boolean isMeaningless(String category) {
        return category == null || MEANINGLESS_CATEGORIES.contains(category.trim());
    }

    private int parsePrice(String priceRaw) {
        if (priceRaw == null) return 0;
        String digits = priceRaw.trim().replaceAll("[^0-9]", "");
        return digits.isBlank() ? 0 : Integer.parseInt(digits);
    }

    private Reader createBomAwareReader(Path csvPath) throws IOException {
        InputStream inputStream = Files.newInputStream(csvPath);
        PushbackInputStream pushbackInputStream = new PushbackInputStream(inputStream, 3);
        byte[] bom = new byte[3];
        int bytesRead = pushbackInputStream.read(bom, 0, bom.length);
        if (bytesRead > 0 && !(bytesRead == 3
                && bom[0] == (byte) 0xEF
                && bom[1] == (byte) 0xBB
                && bom[2] == (byte) 0xBF)) {
            pushbackInputStream.unread(bom, 0, bytesRead);
        }
        return new InputStreamReader(pushbackInputStream, StandardCharsets.UTF_8);
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
                .orElseThrow(() -> new IllegalStateException("Company not found."));
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("Member not found."));

        ProductItem item = ProductItem.createManually(
                company, member, request.productName(), request.price(), request.description());
        if (request.categories() != null) {
            request.categories().forEach(item::addCategory);
        }
        productItemRepository.saveAndFlush(item);
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
                .orElseThrow(() -> new IllegalStateException("Member not found."));

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
                .orElseThrow(() -> new IllegalStateException("Member not found."));

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