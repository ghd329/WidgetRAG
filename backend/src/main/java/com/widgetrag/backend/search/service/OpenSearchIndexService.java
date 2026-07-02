package com.widgetrag.backend.search.service;

import com.widgetrag.backend.product.entity.ProductItem;
import com.widgetrag.backend.search.dto.SearchedProductDto;
import lombok.RequiredArgsConstructor;
import org.opensearch.client.opensearch.OpenSearchClient;
import org.opensearch.client.opensearch._types.mapping.Property;
import org.opensearch.client.opensearch._types.mapping.TypeMapping;
import org.opensearch.client.opensearch._types.query_dsl.Query;
import org.opensearch.client.opensearch.core.BulkResponse;
import org.opensearch.client.opensearch.core.SearchRequest;
import org.opensearch.client.opensearch.core.SearchResponse;
import org.opensearch.client.opensearch.core.bulk.BulkOperation;
import org.opensearch.client.opensearch.indices.CreateIndexRequest;
import org.opensearch.client.opensearch.indices.ExistsRequest;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
@RequiredArgsConstructor
public class OpenSearchIndexService {

    private static final String INDEX_NAME = "product_items_exaone_test";
    private static final int TOP_K = 3;
    private static final int INDEX_BATCH_SIZE = 100;

    private final OpenSearchClient client;
    private final AiServerClient aiServerClient;

    public void ensureIndexExists() {
        try {
            boolean exists = client.indices().exists(ExistsRequest.of(e -> e.index(INDEX_NAME))).value();
            if (!exists) {
                createIndex();
            }
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch index check failed.", e);
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
                .properties("product_url", Property.of(p -> p.keyword(k -> k)))
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
        indexProductItems(List.of(item));
    }

    public void indexProductItems(List<ProductItem> items) {
        if (items == null || items.isEmpty()) return;

        try {
            for (List<ProductItem> batch : partition(items, INDEX_BATCH_SIZE)) {
                List<String> chunkTexts = batch.stream()
                        .map(this::buildChunkText)
                        .toList();
                List<List<Float>> vectors = aiServerClient.embedBatch(chunkTexts);

                List<BulkOperation> operations = new ArrayList<>();
                for (int i = 0; i < batch.size(); i++) {
                    ProductItem item = batch.get(i);
                    String chunkText = chunkTexts.get(i);
                    List<Float> vector = vectors.get(i);

                    operations.add(BulkOperation.of(operation -> operation
                            .index(index -> index
                                    .id(String.valueOf(item.getId()))
                                    .document(buildDocument(item, chunkText, vector))
                            )
                    ));
                }

                BulkResponse response = client.bulk(bulk -> bulk
                        .index(INDEX_NAME)
                        .operations(operations)
                );
                if (response.errors()) {
                    throw new RuntimeException("OpenSearch bulk indexing completed with item errors.");
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch indexing failed.", e);
        }
    }

    private Map<String, Object> buildDocument(ProductItem item, String chunkText, List<Float> vector) {
        Map<String, Object> document = new HashMap<>();
        document.put("company_id", item.getCompany().getId());
        document.put("client_code", item.getCompany().getClientCode());
        document.put("product_item_id", item.getId());
        document.put("product_name", item.getProductName());
        document.put("price", item.getPrice());
        document.put("categories", item.getCategoryNames());
        document.put("description", item.getDescription());
        document.put("product_url", item.getProductUrl());
        document.put("chunk_text", chunkText);
        document.put("chunk_vector", vector);
        return document;
    }

    public void deleteProductItem(Long productItemId) {
        try {
            client.delete(d -> d.index(INDEX_NAME).id(String.valueOf(productItemId)));
        } catch (IOException e) {
            throw new RuntimeException("OpenSearch delete failed.", e);
        }
    }

    private String buildChunkText(ProductItem item) {
        String categories = String.join(", ", item.getCategoryNames());
        return String.format("상품명: %s 가격: %,d원 카테고리: %s 설명: %s",
                item.getProductName(), item.getPrice(), categories, item.getDescription());
    }

    private <T> List<List<T>> partition(List<T> values, int batchSize) {
        List<List<T>> batches = new ArrayList<>();
        for (int i = 0; i < values.size(); i += batchSize) {
            batches.add(values.subList(i, Math.min(i + batchSize, values.size())));
        }
        return batches;
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
                                (String) source.get("product_url")
                        );
                    })
                    .toList();

        } catch (IOException e) {
            throw new RuntimeException("OpenSearch search failed.", e);
        }
    }
}
