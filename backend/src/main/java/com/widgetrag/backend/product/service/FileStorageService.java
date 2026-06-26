package com.widgetrag.backend.product.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.config.StorageProperties;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import com.widgetrag.backend.product.dto.ProductListItemDto;
import com.widgetrag.backend.product.dto.UploadResponseDto;
import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.exception.*;
import com.widgetrag.backend.product.repository.ProductRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.Set;

@Service
@RequiredArgsConstructor
public class FileStorageService {

    private static final Set<String> ALLOWED_EXTENSIONS = Set.of("txt", "csv");
    private static final long MAX_FILE_SIZE = 50L * 1024 * 1024; // 50MB

    private final ProductRepository productRepository;
    private final CompanyRepository companyRepository;
    private final MemberRepository memberRepository;
    private final StorageProperties storageProperties;
    private final ProductItemService productItemService;

    @Transactional
    public UploadResponseDto upload(MultipartFile file, Long companyId, Long memberId) {

        // 1. 형식 검증
        String originalFilename = file.getOriginalFilename();
        String extension = extractExtension(originalFilename);
        if (!ALLOWED_EXTENSIONS.contains(extension)) {
            throw new InvalidFileFormatException(originalFilename);
        }

        // 2. 용량 검증
        if (file.getSize() > MAX_FILE_SIZE) {
            throw new FileSizeExceededException(file.getSize(), MAX_FILE_SIZE);
        }

        // 3. 연관 엔티티 조회
        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalStateException("회사 정보를 찾을 수 없습니다."));
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        // 4. 메타데이터 우선 저장 (file_id 확보 목적)
        Product product = Product.create(company, member, originalFilename, extension, "");
        productRepository.save(product);

        // 5. WSL 격리 경로에 실제 파일 저장
        String storagePath = buildStoragePath(company.getClientCode(), product.getFileId(), originalFilename);
        saveToFileSystem(file, storagePath);

        // 6. 저장 경로 업데이트
        if ("csv".equalsIgnoreCase(extension)) {
            productItemService.parseAndSaveFromCsv(Paths.get(storagePath), company, product, member);
        }

        return new UploadResponseDto(
                product.getFileId(),
                product.getFileName(),
                product.getFileType(),
                product.getStatus()
        );
    }

    private String extractExtension(String filename) {
        if (filename == null || !filename.contains(".")) {
            return "";
        }
        return filename.substring(filename.lastIndexOf('.') + 1).toLowerCase();
    }

    private String buildStoragePath(String clientCode, Long fileId, String originalFilename) {
        return Paths.get(storageProperties.getBasePath(), clientCode, fileId + "_" + originalFilename)
                .toString();
    }

    private void saveToFileSystem(MultipartFile file, String storagePath) {
        try {
            Path path = Paths.get(storagePath);
            Files.createDirectories(path.getParent()); // client_code 폴더 없으면 생성
            file.transferTo(path);
        } catch (IOException e) {
            throw new FileStorageException("파일 저장 중 오류가 발생했습니다.", e);
        }
    }

    @Transactional(readOnly = true)
    public List<ProductListItemDto> getProductList(Long companyId) {
        return productRepository.findByCompanyIdAndDeletedAtIsNull(companyId)
                .stream()
                .map(p -> new ProductListItemDto(
                        p.getFileId(), p.getFileName(), p.getFileType(),
                        p.getStatus(), p.getUploadedAt(), p.getUpdatedAt()
                ))
                .toList();
    }

    @Transactional
    public UploadResponseDto update(Long fileId, MultipartFile file, Long companyId, Long memberId) {

        Product product = productRepository.findById(fileId)
                .orElseThrow(() -> new ProductNotFoundException(fileId));

        if (!product.getCompany().getId().equals(companyId)) {
            throw new ProductAccessDeniedException();
        }

        String originalFilename = file.getOriginalFilename();
        String extension = extractExtension(originalFilename);
        if (!ALLOWED_EXTENSIONS.contains(extension)) {
            throw new InvalidFileFormatException(originalFilename);
        }
        if (file.getSize() > MAX_FILE_SIZE) {
            throw new FileSizeExceededException(file.getSize(), MAX_FILE_SIZE);
        }

        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        // 기존 파일 물리 삭제 후 새 파일 저장 (같은 file_id 경로 재사용)
        deletePhysicalFile(product.getStoragePath());
        String newStoragePath = buildStoragePath(product.getCompany().getClientCode(), product.getFileId(), originalFilename);
        saveToFileSystem(file, newStoragePath);

        product.updateContent(originalFilename, extension, newStoragePath, member);

        return new UploadResponseDto(product.getFileId(), product.getFileName(), product.getFileType(), product.getStatus());
    }

    @Transactional
    public void delete(Long fileId, Long companyId, Long memberId) {

        Product product = productRepository.findById(fileId)
                .orElseThrow(() -> new ProductNotFoundException(fileId));

        if (!product.getCompany().getId().equals(companyId)) {
            throw new ProductAccessDeniedException();
        }

        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        deletePhysicalFile(product.getStoragePath()); // WSL 실제 파일 즉시 삭제
        product.markAsDeleted(member); // DB는 soft delete
    }

    private void deletePhysicalFile(String storagePath) {
        try {
            Files.deleteIfExists(Paths.get(storagePath));
        } catch (IOException e) {
            throw new FileStorageException("파일 삭제 중 오류가 발생했습니다.", e);
        }
    }
}