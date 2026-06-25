package com.widgetrag.backend.product.entity;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.member.entity.Member;
import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;

@Entity
@Table(name = "product")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class Product {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "file_id")
    private Long fileId;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "company_id", nullable = false)
    private Company company; // 어느 회사 소속 파일인지 (멀티 테넌시 격리 기준)

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "uploaded_by", nullable = false)
    private Member uploadedBy; // 최초 업로드한 직원

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "updated_by")
    private Member updatedBy; // 마지막 수정한 직원 (없으면 NULL)

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "deleted_by")
    private Member deletedBy; // 삭제한 직원 (없으면 NULL)

    @Column(name = "file_name", length = 255, nullable = false)
    private String fileName;

    @Column(name = "file_type", length = 10, nullable = false)
    private String fileType; // txt 또는 csv

    @Column(name = "storage_path", length = 500, nullable = false)
    private String storagePath; // WSL 격리 저장 경로

    @Column(name = "uploaded_at", nullable = false)
    private LocalDateTime uploadedAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @Column(name = "deleted_at")
    private LocalDateTime deletedAt; // NULL이면 삭제 안 된 정상 파일

    @Column(name = "status", length = 20, nullable = false)
    private String status; // UPLOADED / VECTORIZED / FAILED

    public static Product create(Company company, Member uploadedBy, String fileName,
                                 String fileType, String storagePath) {
        Product product = new Product();
        product.company = company;
        product.uploadedBy = uploadedBy;
        product.fileName = fileName;
        product.fileType = fileType;
        product.storagePath = storagePath;
        product.uploadedAt = LocalDateTime.now();
        product.status = "UPLOADED";
        return product;
    }

    // 도메인 의도가 드러나는 메서드 - 단순 setter 대신
    public void markAsUpdated(Member member) {
        this.updatedBy = member;
        this.updatedAt = LocalDateTime.now();
    }

    public void markAsDeleted(Member member) {
        this.deletedBy = member;
        this.deletedAt = LocalDateTime.now();
    }

    public void changeStatus(String status) {
        this.status = status;
    }

    public boolean isDeleted() {
        return this.deletedAt != null;
    }

    public void updateStoragePath(String storagePath) {
        this.storagePath = storagePath;
    }
}