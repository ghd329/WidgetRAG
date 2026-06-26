package com.widgetrag.backend.product.entity;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.member.entity.Member;
import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;

@Entity
@Table(name = "product_item")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class ProductItem {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "company_id", nullable = false)
    private Company company;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "source_file_id")
    private Product sourceFile; // CSV 업로드로 생성됐으면 채워짐, 화면에서 직접 추가했으면 null

    @Column(name = "product_name", length = 200, nullable = false)
    private String productName;

    @Column(name = "price", nullable = false)
    private int price;

    @Column(name = "category", length = 100)
    private String category;

    @Column(name = "description", columnDefinition = "TEXT")
    private String description;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "created_by", nullable = false)
    private Member createdBy;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "updated_by")
    private Member updatedBy;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "deleted_by")
    private Member deletedBy;

    @Column(name = "created_at", nullable = false)
    private LocalDateTime createdAt;

    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    @Column(name = "deleted_at")
    private LocalDateTime deletedAt;

    public static ProductItem createFromFile(Company company, Product sourceFile, Member createdBy,
                                             String productName, int price, String category, String description) {
        ProductItem item = new ProductItem();
        item.company = company;
        item.sourceFile = sourceFile;
        item.createdBy = createdBy;
        item.productName = productName;
        item.price = price;
        item.category = category;
        item.description = description;
        item.createdAt = LocalDateTime.now();
        return item;
    }

    public static ProductItem createManually(Company company, Member createdBy,
                                             String productName, int price, String category, String description) {
        return createFromFile(company, null, createdBy, productName, price, category, description);
    }

    public void update(String productName, int price, String category, String description, Member member) {
        this.productName = productName;
        this.price = price;
        this.category = category;
        this.description = description;
        this.updatedBy = member;
        this.updatedAt = LocalDateTime.now();
    }

    public void markAsDeleted(Member member) {
        this.deletedBy = member;
        this.deletedAt = LocalDateTime.now();
    }
}