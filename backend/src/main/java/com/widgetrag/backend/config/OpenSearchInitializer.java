package com.widgetrag.backend.config;

import com.widgetrag.backend.search.service.OpenSearchIndexService;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class OpenSearchInitializer {

    private final OpenSearchIndexService openSearchIndexService;

    @PostConstruct
    public void init() {
        openSearchIndexService.ensureIndexExists();
    }
}