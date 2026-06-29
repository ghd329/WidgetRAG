package com.widgetrag.backend.search.service;

import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.util.List;
import java.util.Map;

@Service
public class AiServerClient {

    private final RestClient restClient;

    public AiServerClient(@Value("${ai-server.base-url}") String baseUrl) {
        this.restClient = RestClient.builder().baseUrl(baseUrl).build();
    }

    public List<Float> embed(String text) {
        Map<String, Object> response = restClient.post()
                .uri("/embed")
                .contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                .body(Map.of("texts", List.of(text)))
                .retrieve()
                .body(Map.class);

        List<List<Double>> embeddings = (List<List<Double>>) response.get("embeddings");
        return embeddings.get(0).stream().map(Double::floatValue).toList();
    }
}