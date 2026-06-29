package com.widgetrag.backend.product.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.entity.CompanyCsvMapping;
import com.widgetrag.backend.company.repository.CompanyCsvMappingRepository;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.product.dto.*;
import com.widgetrag.backend.product.exception.TempFileNotFoundException;
import lombok.RequiredArgsConstructor;
import org.apache.commons.csv.CSVFormat;
import org.apache.commons.csv.CSVRecord;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;

@Service
@RequiredArgsConstructor
public class CsvUploadService {

    private static final String TEMP_DIR = System.getProperty("java.io.tmpdir") + "/widgetrag-temp";
    private static final int PREVIEW_ROW_COUNT = 3;

    private final CompanyRepository companyRepository;
    private final CompanyCsvMappingRepository mappingRepository;

    // 1단계: 파일을 임시 저장하고 헤더/샘플/추천 매핑을 반환
    public CsvPreviewResponseDto preview(MultipartFile file, Long companyId) {

        String token = UUID.randomUUID().toString();
        Path tempPath = saveTempFile(file, token);

        List<String> headers;
        List<Map<String, String>> sampleRows = new ArrayList<>();

        try (Reader reader = createBomAwareReader(tempPath)) {
            CSVFormat format = CSVFormat.DEFAULT.builder()
                    .setHeader()
                    .setSkipHeaderRecord(true)
                    .setTrim(true)
                    .build();

            org.apache.commons.csv.CSVParser parser = format.parse(reader);
            headers = new ArrayList<>(parser.getHeaderNames());

            int count = 0;
            for (CSVRecord record : parser) {
                if (count >= PREVIEW_ROW_COUNT) break;
                Map<String, String> row = new LinkedHashMap<>();
                for (String header : headers) {
                    row.put(header, record.isMapped(header) ? record.get(header) : "");
                }
                sampleRows.add(row);
                count++;
            }
        } catch (IOException e) {
            throw new RuntimeException("CSV 미리보기 중 오류가 발생했습니다.", e);
        }

        Optional<CompanyCsvMapping> savedMapping = mappingRepository.findByCompanyId(companyId);

        CsvMappingDto suggested = savedMapping
                .map(this::toMappingDto)
                .orElseGet(() -> suggestMapping(headers));

        return new CsvPreviewResponseDto(token, headers, sampleRows, suggested, savedMapping.isPresent());
    }

    // 2단계: 매핑 정보를 받아 실제 파싱 진행 (FileStorageService에서 호출)
    public Path resolveTempFile(String token) {
        Path path = Paths.get(TEMP_DIR, token + ".csv");
        if (!Files.exists(path)) {
            throw new TempFileNotFoundException(token);
        }
        return path;
    }

    @Transactional
    public void saveMappingIfRequested(CsvUploadConfirmRequestDto request, Long companyId) {
        if (!request.saveAsDefault()) return;

        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalStateException("회사 정보를 찾을 수 없습니다."));

        CsvMappingDto m = request.mapping();

        mappingRepository.findByCompanyId(companyId)
                .ifPresentOrElse(
                        existing -> existing.update(m.productIdColumn(), m.productNameColumn(),
                                m.priceColumn(), m.categoryColumn(), m.descriptionColumn()),
                        () -> mappingRepository.save(CompanyCsvMapping.create(
                                company, m.productIdColumn(), m.productNameColumn(),
                                m.priceColumn(), m.categoryColumn(), m.descriptionColumn()))
                );
    }

    public void cleanupTempFile(String token) {
        try {
            Files.deleteIfExists(Paths.get(TEMP_DIR, token + ".csv"));
        } catch (IOException ignored) {
        }
    }

    private Path saveTempFile(MultipartFile file, String token) {
        try {
            Path dir = Paths.get(TEMP_DIR);
            Files.createDirectories(dir);
            Path path = dir.resolve(token + ".csv");
            file.transferTo(path);
            return path;
        } catch (IOException e) {
            throw new RuntimeException("임시 파일 저장 중 오류가 발생했습니다.", e);
        }
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

    // 헤더 이름 기반으로 합리적인 기본 매핑을 추측 (사용자가 고치기 쉽게)
    private CsvMappingDto suggestMapping(List<String> headers) {
        return new CsvMappingDto(
                findBestMatch(headers, List.of("product_id", "상품id", "id")),
                findBestMatch(headers, List.of("product_name", "상품명", "name", "title")),
                findBestMatch(headers, List.of("price", "가격", "판매가")),
                findBestMatch(headers, List.of("category", "category_leaf", "category_main", "카테고리")),
                findBestMatch(headers, List.of("description", "상품설명", "설명"))
        );
    }

    private String findBestMatch(List<String> headers, List<String> candidates) {
        for (String candidate : candidates) {
            for (String header : headers) {
                if (header.equalsIgnoreCase(candidate)) return header;
            }
        }
        return null;
    }

    private CsvMappingDto toMappingDto(CompanyCsvMapping mapping) {
        return new CsvMappingDto(
                mapping.getProductIdColumn(), mapping.getProductNameColumn(),
                mapping.getPriceColumn(), mapping.getCategoryColumn(), mapping.getDescriptionColumn()
        );
    }
}