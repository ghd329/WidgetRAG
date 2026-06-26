package com.widgetrag.backend.product.repository;

import com.widgetrag.backend.product.entity.ProductItem;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface ProductItemRepository extends JpaRepository<ProductItem, Long> {

    List<ProductItem> findByCompanyIdAndDeletedAtIsNull(Long companyId);

    Optional<ProductItem> findByIdAndDeletedAtIsNull(Long id);
}