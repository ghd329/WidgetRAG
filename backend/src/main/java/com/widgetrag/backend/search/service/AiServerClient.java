package com.widgetrag.backend.search.service;

import com.widgetrag.backend.chat.dto.RetrievedProductDto;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
public class AiServerClient {

    private final RestClient restClient;

    public AiServerClient(@Value("${ai-server.base-url}") String baseUrl) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(5000);
        factory.setReadTimeout(30000);

        this.restClient = RestClient.builder()
                .baseUrl(baseUrl)
                .requestFactory(factory)
                .build();
    }

    public List<Float> embed(String text) {
        Map<String, Object> response = restClient.post()
                .uri("/embed")
                .contentType(MediaType.APPLICATION_JSON)
                .body(Map.of("texts", List.of(text)))
                .retrieve()
                .body(Map.class);

        List<List<Double>> embeddings = (List<List<Double>>) response.get("embeddings");
        return embeddings.get(0).stream().map(Double::floatValue).toList();
    }

    public List<List<Float>> embedBatch(List<String> texts) {
        try {
            Map<String, Object> body = new HashMap<>();
            body.put("texts", texts);

            Map<String, List<List<Double>>> response = restClient.post()
                    .uri("/embed")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(new ParameterizedTypeReference<>() {});

            return response.get("embeddings").stream()
                    .map(vector -> vector.stream().map(Double::floatValue).toList())
                    .toList();
        } catch (Exception e) {
            throw new RuntimeException("AI batch embedding request failed.", e);
        }
    }

    public String generate(String clientCode, String question, List<RetrievedProductDto> products) {
        List<Map<String, Object>> productContexts = products.stream()
                .map(p -> Map.<String, Object>of(
                        "productName", p.productName(),
                        "price", p.price(),
                        "category", p.category()
                ))
                .toList();

        Map<String, Object> requestBody = Map.of(
                "clientCode", clientCode,
                "question", question,
                "products", productContexts
        );

        Map<String, Object> response = restClient.post()
                .uri("/generate")
                .contentType(MediaType.APPLICATION_JSON)
                .body(requestBody)
                .retrieve()
                .body(Map.class);

        return (String) response.get("answer");
    }
}
