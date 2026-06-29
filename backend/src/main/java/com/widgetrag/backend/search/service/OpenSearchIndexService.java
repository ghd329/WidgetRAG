package com.widgetrag.backend.search.service;

import com.widgetrag.backend.product.entity.ProductItem;
import com.widgetrag.backend.search.dto.SearchedProductDto;
import lombok.RequiredArgsConstructor;
import org.opensearch.client.opensearch.OpenSearchClient;
import org.opensearch.client.opensearch._types.mapping.Property;
import org.opensearch.client.opensearch._types.mapping.TypeMapping;
import org.opensearch.client.opensearch._types.query_dsl.Query;
import org.opensearch.client.opensearch.core.SearchRequest;
import org.opensearch.client.opensearch.core.SearchResponse;
import org.opensearch.client.opensearch.indices.CreateIndexRequest;
import org.opensearch.client.opensearch.indices.ExistsRequest;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class OpenSearchIndexService {

    private static final String INDEX_NAME = "product_items";
    private static final int TOP_K = 3;

    private final OpenSearchClient client;

    public void ensureIndexExists() {
        try {
            boolean exists = client.indices().exists(ExistsRequest.of(e -> e.index(INDEX_NAME))).value();
            if (!exists) {
                createIndex();
            }
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch 인덱스 확인 중 오류가 발생했습니다.", e);
        }
    }

    private void createIndex() throws IOException {
        TypeMapping mapping = TypeMapping.of(m -> m
                .properties("company_id", Property.of(p -> p.long_(l -> l)))
                .properties("client_code", Property.of(p -> p.keyword(k -> k)))
                .properties("product_item_id", Property.of(p -> p.long_(l -> l)))
                .properties("product_name", Property.of(p -> p.text(t -> t)))
                .properties("price", Property.of(p -> p.integer(i -> i)))
                .properties("categories", Property.of(p -> p.keyword(k -> k)))
                .properties("chunk_text", Property.of(p -> p.text(t -> t)))
        );

        CreateIndexRequest request = CreateIndexRequest.of(c -> c
                .index(INDEX_NAME)
                .mappings(mapping)
        );

        client.indices().create(request);
    }

    // 상품 1개 = 1청크 (모델정의서 3.2)
    public void indexProductItem(ProductItem item) {
        try {
            String chunkText = buildChunkText(item);

            Map<String, Object> document = Map.of(
                    "company_id", item.getCompany().getId(),
                    "client_code", item.getCompany().getClientCode(),
                    "product_item_id", item.getId(),
                    "product_name", item.getProductName(),
                    "price", item.getPrice(),
                    "categories", item.getCategoryNames(),
                    "chunk_text", chunkText
            );

            client.index(i -> i
                    .index(INDEX_NAME)
                    .id(String.valueOf(item.getId()))
                    .document(document)
            );
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch 색인 중 오류가 발생했습니다.", e);
        }
    }

    public void deleteProductItem(Long productItemId) {
        try {
            client.delete(d -> d.index(INDEX_NAME).id(String.valueOf(productItemId)));
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch 색인 삭제 중 오류가 발생했습니다.", e);
        }
    }

    // 모델정의서 3.2 청킹 전략 - 상품명 │ 가격 │ 카테고리 │ 설명
    private String buildChunkText(ProductItem item) {
        String categories = String.join(", ", item.getCategoryNames());
        return String.format("상품명: %s │ 가격: %,d원 │ 카테고리: %s │ 설명: %s",
                item.getProductName(), item.getPrice(), categories, item.getDescription());
    }

    public List<SearchedProductDto> search(String clientCode, String question) {
        try {
            Query clientCodeFilter = Query.of(q -> q
                    .term(t -> t.field("client_code").value(v -> v.stringValue(clientCode)))
            );

            Query textMatch = Query.of(q -> q
                    .match(m -> m
                            .field("chunk_text")
                            .query(v -> v.stringValue(question))
                            .minimumShouldMatch("60%") // 질문 단어의 60% 이상 매칭돼야 함
                    )
            );

            Query combined = Query.of(q -> q
                    .bool(b -> b
                            .filter(clientCodeFilter)
                            .must(textMatch)
                    )
            );

            SearchRequest request = SearchRequest.of(s -> s
                    .index(INDEX_NAME)
                    .query(combined)
                    .size(TOP_K)
                    .minScore(0.3) // 보조 안전망, 낮은 값
            );

            SearchResponse<Map> response = client.search(request, Map.class);

            return response.hits().hits().stream()
                    .map(hit -> {
                        Map<String, Object> source = hit.source();
                        return new SearchedProductDto(
                                ((Number) source.get("product_item_id")).longValue(),
                                (String) source.get("product_name"),
                                ((Number) source.get("price")).intValue(),
                                (List<String>) source.get("categories")
                        );
                    })
                    .toList();

        } catch (IOException e) {
            throw new RuntimeException("OpenSearch 검색 중 오류가 발생했습니다.", e);
        }
    }
}