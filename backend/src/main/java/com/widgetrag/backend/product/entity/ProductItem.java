package com.widgetrag.backend.product.entity;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.member.entity.Member;
import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

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
    private Product sourceFile;

    @Column(name = "external_product_id", length = 50)
    private String externalProductId;

    @Column(name = "product_name", length = 200, nullable = false)
    private String productName;

    @Column(name = "price", nullable = false)
    private int price;

    @Column(name = "description", columnDefinition = "TEXT")
    private String description;

    @Column(name = "product_url", length = 500)
    private String productUrl;

    @OneToMany(mappedBy = "productItem", cascade = CascadeType.ALL, orphanRemoval = true)
    private List<ProductItemCategory> categories = new ArrayList<>();

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
                                             String externalProductId, String productName, int price,
                                             String description, String productUrl) {
        ProductItem item = new ProductItem();
        item.company = company;
        item.sourceFile = sourceFile;
        item.externalProductId = externalProductId;
        item.createdBy = createdBy;
        item.productName = productName;
        item.price = price;
        item.description = description;
        item.productUrl = productUrl;
        item.createdAt = LocalDateTime.now();
        return item;
    }

    public static ProductItem createManually(Company company, Member createdBy,
                                             String productName, int price, String description) {
        // URL 없는 수동 등록이므로 null 전달
        return createFromFile(company, null, createdBy, null, productName, price, description, null);
    }

    public void addCategory(String category) {
        if (category == null || category.isBlank()) return;
        boolean exists = this.categories.stream()
                .anyMatch(c -> c.getCategory().equals(category));
        if (!exists) {
            this.categories.add(ProductItemCategory.create(this, category));
        }
    }

    public List<String> getCategoryNames() {
        return this.categories.stream().map(ProductItemCategory::getCategory).toList();
    }

    public void update(String productName, int price, String description, String productUrl, Member member) {
        this.productName = productName;
        this.price = price;
        this.description = description;
        this.productUrl = productUrl;
        this.updatedBy = member;
        this.updatedAt = LocalDateTime.now();
    }

    public boolean hasDifferentContent(String productName, int price, String description, String productUrl) {
        return !Objects.equals(this.productName, productName)
                || this.price != price
                || !Objects.equals(this.description, description)
                || !Objects.equals(this.productUrl, productUrl);
    }

    public void markAsDeleted(Member member) {
        this.deletedBy = member;
        this.deletedAt = LocalDateTime.now();
    }
}