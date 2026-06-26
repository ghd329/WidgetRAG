package com.widgetrag.backend.company.entity;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;

@Entity
@Table(name = "company_csv_mapping")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class CompanyCsvMapping {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @OneToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "company_id", nullable = false, unique = true)
    private Company company;

    @Column(name = "product_id_column", length = 100)
    private String productIdColumn;

    @Column(name = "product_name_column", length = 100, nullable = false)
    private String productNameColumn;

    @Column(name = "price_column", length = 100, nullable = false)
    private String priceColumn;

    @Column(name = "category_column", length = 100)
    private String categoryColumn;

    @Column(name = "description_column", length = 100)
    private String descriptionColumn;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    public static CompanyCsvMapping create(Company company, String productIdColumn, String productNameColumn,
                                           String priceColumn, String categoryColumn, String descriptionColumn) {
        CompanyCsvMapping mapping = new CompanyCsvMapping();
        mapping.company = company;
        mapping.productIdColumn = productIdColumn;
        mapping.productNameColumn = productNameColumn;
        mapping.priceColumn = priceColumn;
        mapping.categoryColumn = categoryColumn;
        mapping.descriptionColumn = descriptionColumn;
        mapping.updatedAt = LocalDateTime.now();
        return mapping;
    }

    public void update(String productIdColumn, String productNameColumn, String priceColumn,
                       String categoryColumn, String descriptionColumn) {
        this.productIdColumn = productIdColumn;
        this.productNameColumn = productNameColumn;
        this.priceColumn = priceColumn;
        this.categoryColumn = categoryColumn;
        this.descriptionColumn = descriptionColumn;
        this.updatedAt = LocalDateTime.now();
    }
}