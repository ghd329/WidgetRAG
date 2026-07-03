package com.widgetrag.backend.product.repository;

import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.entity.ProductFileItem;
import com.widgetrag.backend.product.entity.ProductItem;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface ProductFileItemRepository extends JpaRepository<ProductFileItem, Long> {

    List<ProductFileItem> findByProductFile(Product productFile);

    long countByProductItemAndProductFileDeletedAtIsNull(ProductItem productItem);

    boolean existsByProductFileAndProductItem(Product productFile, ProductItem productItem);
}