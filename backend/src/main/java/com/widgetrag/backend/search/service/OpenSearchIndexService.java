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
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class OpenSearchIndexService {

    private static final String INDEX_NAME = "product_items";
    private static final int TOP_K = 3;

    private final OpenSearchClient client;
    private final AiServerClient aiServerClient;

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
                .properties("description", Property.of(p -> p.text(t -> t)))
                .properties("product_url", Property.of(p -> p.keyword(k -> k))) // 추가
                .properties("chunk_text", Property.of(p -> p.text(t -> t)))
                .properties("chunk_vector", Property.of(p -> p.knnVector(k -> k
                        .dimension(1024)
                        .method(meth -> meth
                                .name("hnsw")
                                .spaceType("cosinesimil")
                                .engine("lucene")
                        )
                )))
        );

        CreateIndexRequest request = CreateIndexRequest.of(c -> c
                .index(INDEX_NAME)
                .settings(s -> s.knn(true))
                .mappings(mapping)
        );

        client.indices().create(request);
    }

    public void indexProductItem(ProductItem item) {
        try {
            String chunkText = buildChunkText(item);
            List<Float> vector = aiServerClient.embed(chunkText);

            // Map.of()는 null 값 허용 안 하므로 HashMap 사용
            Map<String, Object> document = new HashMap<>();
            document.put("company_id", item.getCompany().getId());
            document.put("client_code", item.getCompany().getClientCode());
            document.put("product_item_id", item.getId());
            document.put("product_name", item.getProductName());
            document.put("price", item.getPrice());
            document.put("categories", item.getCategoryNames());
            document.put("description", item.getDescription());
            document.put("product_url", item.getProductUrl()); // null 허용 — Map.of() 대신 HashMap 쓰는 이유
            document.put("chunk_text", chunkText);
            document.put("chunk_vector", vector);

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

    private String buildChunkText(ProductItem item) {
        String categories = String.join(", ", item.getCategoryNames());
        return String.format("상품명: %s │ 가격: %,d원 │ 카테고리: %s │ 설명: %s",
                item.getProductName(), item.getPrice(), categories, item.getDescription());
    }

    public List<SearchedProductDto> search(String clientCode, String question) {
        try {
            List<Float> queryVector = aiServerClient.embed(question);

            Query clientCodeFilter = Query.of(q -> q
                    .term(t -> t.field("client_code").value(v -> v.stringValue(clientCode)))
            );

            Query knnQuery = Query.of(q -> q
                    .knn(k -> k
                            .field("chunk_vector")
                            .vector(queryVector)
                            .k(TOP_K)
                            .filter(clientCodeFilter)
                    )
            );

            SearchRequest request = SearchRequest.of(s -> s
                    .index(INDEX_NAME)
                    .query(knnQuery)
                    .size(TOP_K)
            );

            SearchResponse<Map> response = client.search(request, Map.class);

            return response.hits().hits().stream()
                    .map(hit -> {
                        Map<String, Object> source = hit.source();
                        return new SearchedProductDto(
                                ((Number) source.get("product_item_id")).longValue(),
                                (String) source.get("product_name"),
                                ((Number) source.get("price")).intValue(),
                                (List<String>) source.get("categories"),
                                (String) source.get("product_url") // 추가
                        );
                    })
                    .toList();

        } catch (IOException e) {
            throw new RuntimeException("OpenSearch 검색 중 오류가 발생했습니다.", e);
        }
    }
}