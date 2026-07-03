package com.widgetrag.backend.product.entity;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;

@Entity
@Table(
        name = "product_file_item",
        uniqueConstraints = {
                @UniqueConstraint(
                        name = "uk_product_file_item",
                        columnNames = {"product_file_id", "product_item_id"}
                )
        }
)
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class ProductFileItem {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "product_file_id", nullable = false)
    private Product productFile;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "product_item_id", nullable = false)
    private ProductItem productItem;

    public static ProductFileItem create(Product productFile, ProductItem productItem) {
        ProductFileItem mapping = new ProductFileItem();
        mapping.productFile = productFile;
        mapping.productItem = productItem;
        return mapping;
    }
}