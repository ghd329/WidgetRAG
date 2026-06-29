package com.widgetrag.backend.product.repository;

import com.widgetrag.backend.product.entity.Product;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface ProductRepository extends JpaRepository<Product, Long> {

    // soft delete 반영 - 삭제 안 된 것만 조회
    List<Product> findByCompany_IdAndDeletedAtIsNull(Long companyId);
}