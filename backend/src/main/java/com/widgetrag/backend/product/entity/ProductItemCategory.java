package com.widgetrag.backend.product.entity;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;

@Entity
@Table(name = "product_item_category",
        uniqueConstraints = @UniqueConstraint(columnNames = {"product_item_id", "category"}))
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class ProductItemCategory {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "product_item_id", nullable = false)
    private ProductItem productItem;

    @Column(name = "category", length = 100, nullable = false)
    private String category;

    @Column(name = "created_at", nullable = false)
    private LocalDateTime createdAt;

    public static ProductItemCategory create(ProductItem productItem, String category) {
        ProductItemCategory pc = new ProductItemCategory();
        pc.productItem = productItem;
        pc.category = category;
        pc.createdAt = LocalDateTime.now();
        return pc;
    }
}