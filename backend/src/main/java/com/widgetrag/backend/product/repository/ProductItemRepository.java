package com.widgetrag.backend.product.repository;

import com.widgetrag.backend.product.entity.Product;
import com.widgetrag.backend.product.entity.ProductItem;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface ProductItemRepository extends JpaRepository<ProductItem, Long> {

    List<ProductItem> findByCompanyIdAndDeletedAtIsNull(Long companyId);

    Optional<ProductItem> findByIdAndDeletedAtIsNull(Long id);

    Optional<ProductItem> findByCompanyIdAndExternalProductIdAndDeletedAtIsNull(Long companyId, String externalProductId);

    @EntityGraph(attributePaths = "categories")
    List<ProductItem> findByCompanyIdAndExternalProductIdInAndDeletedAtIsNull(Long companyId, Collection<String> externalProductIds);

    List<ProductItem> findBySourceFileAndDeletedAtIsNull(Product sourceFile);

    List<ProductItem> findByCompanyClientCodeAndDeletedAtIsNull(String clientCode);
}
