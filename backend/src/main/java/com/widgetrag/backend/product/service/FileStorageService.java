package com.widgetrag.backend.product.service;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.config.StorageProperties;
import com.widgetrag.backend.member.entity.Member;
import com.widgetrag.backend.member.repository.MemberRepository;
import com.widgetrag.backend.product.dto.CsvUploadConfirmRequestDto;
import com.widgetrag.backend.product.dto.IncrementalUploadResultDto;
import com.widgetrag.backend.product.dto.ProductListItemDto;
import com.widgetrag.backend.product.dto.UploadResponseDto;
import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.entity.ProductItem;
import com.widgetrag.backend.product.exception.*;
import com.widgetrag.backend.product.repository.ProductItemRepository;
import com.widgetrag.backend.product.repository.ProductRepository;
import com.widgetrag.backend.search.service.OpenSearchIndexService;

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

    private static final Set<String> ALLOWED_EXTENSIONS = Set.of("csv");
    private static final long MAX_FILE_SIZE = 50L * 1024 * 1024;

    private final ProductRepository productRepository;
    private final CompanyRepository companyRepository;
    private final MemberRepository memberRepository;
    private final StorageProperties storageProperties;
    private final ProductItemService productItemService;
    private final CsvUploadService csvUploadService;
    private final ProductItemRepository productItemRepository;
    private final OpenSearchIndexService openSearchIndexService;

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
            Files.createDirectories(path.getParent());
            file.transferTo(path);
        } catch (IOException e) {
            throw new FileStorageException("파일 저장 중 오류가 발생했습니다.", e);
        }
    }

    @Transactional(readOnly = true)
    public List<ProductListItemDto> getProductList(Long companyId) {
        return productRepository.findByCompany_IdAndDeletedAtIsNull(companyId)
                .stream()
                .map(p -> new ProductListItemDto(
                        p.getFileId(), p.getFileName(), p.getFileType(),
                        p.getStatus(), p.getUploadedAt(), p.getUpdatedAt()
                ))
                .toList();
    }

    // ===== update 메서드 복구 (이전 작업에서 빠짐) =====
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

        deletePhysicalFile(product.getStoragePath());
        String newStoragePath = buildStoragePath(product.getCompany().getClientCode(), product.getFileId(), originalFilename);
        saveToFileSystem(file, newStoragePath);

        product.updateContent(originalFilename, extension, newStoragePath, member);

        return new UploadResponseDto(
                product.getFileId(), product.getFileName(), product.getFileType(),
                product.getStatus(), null
        );
    }

    @Transactional
    public void delete(Long fileId, Long companyId, Long memberId) {
        Product product = productRepository.findById(fileId)
                .orElseThrow(() -> new IllegalStateException("업로드 파일을 찾을 수 없습니다."));

        if (!product.getCompany().getId().equals(companyId)) {
            throw new ProductAccessDeniedException();
        }

        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        List<ProductItem> items =
            productItemRepository.findBySourceFileFileIdAndDeletedAtIsNull(fileId);

        for (ProductItem item : items) {
            item.markAsDeleted(member);
            openSearchIndexService.deleteProductItem(item.getId());
        }

        deletePhysicalFile(product.getStoragePath());

        product.markAsDeleted(member);
    }

    private void deletePhysicalFile(String storagePath) {
        try {
            Files.deleteIfExists(Paths.get(storagePath));
        } catch (IOException e) {
            throw new FileStorageException("파일 삭제 중 오류가 발생했습니다.", e);
        }
    }

    @Transactional
    public UploadResponseDto confirmUpload(CsvUploadConfirmRequestDto request, Long companyId, Long memberId) {

        Path tempPath = csvUploadService.resolveTempFile(request.tempFileToken());

        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalStateException("회사 정보를 찾을 수 없습니다."));
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new IllegalStateException("회원 정보를 찾을 수 없습니다."));

        String originalFilename = request.originalFilename();
        Product product = Product.create(company, member, originalFilename, "csv", "");
        productRepository.save(product);
        

        String storagePath = buildStoragePath(company.getClientCode(), product.getFileId(), originalFilename);
        try {
            Files.createDirectories(Paths.get(storagePath).getParent());
            Files.copy(tempPath, Paths.get(storagePath));
        } catch (IOException e) {
            throw new FileStorageException("파일 저장 중 오류가 발생했습니다.", e);
        }
        product.updateStoragePath(storagePath);

        csvUploadService.saveMappingIfRequested(request, companyId);

        IncrementalUploadResultDto itemResult = productItemService.parseAndSaveFromCsv(
                tempPath, company, product, member, request.mapping());

        csvUploadService.cleanupTempFile(request.tempFileToken());

        return new UploadResponseDto(
                product.getFileId(), product.getFileName(), product.getFileType(),
                product.getStatus(), itemResult
        );
    }
}