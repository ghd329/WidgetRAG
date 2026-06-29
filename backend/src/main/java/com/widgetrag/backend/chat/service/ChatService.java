package com.widgetrag.backend.chat.service;

import com.widgetrag.backend.chat.dto.ChatQueryRequestDto;
import com.widgetrag.backend.chat.dto.ChatQueryResponseDto;
import com.widgetrag.backend.chat.dto.RetrievedProductDto;
import com.widgetrag.backend.chat.exception.InvalidClientCodeException;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.search.dto.SearchedProductDto;
import com.widgetrag.backend.search.service.AiServerClient;
import com.widgetrag.backend.search.service.OpenSearchIndexService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClientException;

import java.util.List;

@Service
@RequiredArgsConstructor
public class ChatService {

    private final CompanyRepository companyRepository;
    private final OpenSearchIndexService openSearchIndexService;
    private final AiServerClient aiServerClient;

    public ChatQueryResponseDto getAnswer(ChatQueryRequestDto request) {

        if (!companyRepository.existsByClientCode(request.clientCode())) {
            throw new InvalidClientCodeException(request.clientCode());
        }

        List<SearchedProductDto> searchResults = openSearchIndexService.search(
                request.clientCode(), request.question());

        // 모델정의서 3.6 Fallback 정책 - 검색 결과 0건이면 목업으로 대체
        if (searchResults.isEmpty()) {
            return buildFallbackResponse(request.question());
        }

        List<RetrievedProductDto> products = searchResults.stream()
                .map(p -> new RetrievedProductDto(
                        p.productItemId(), p.productName(), p.price(), String.join(", ", p.categories())))
                .toList();

        try {
            String answer = aiServerClient.generate(request.clientCode(), request.question(), products);
            return new ChatQueryResponseDto(answer, products, false);
        } catch (RestClientException e) {
            // 모델정의서 3.6 Fallback 정책 - GPU 서버 응답 지연/실패 시 목업으로 대체
            return buildFallbackResponse(request.question());
        }
    }

    private ChatQueryResponseDto buildFallbackResponse(String question) {
        List<RetrievedProductDto> mockProducts = List.of(
                new RetrievedProductDto(null, "린넨 셔츠", 29900, "셔츠/블라우스")
        );
        String mockAnswer = String.format(
                "'%s'에 대한 검색 결과가 없어 예시 데이터로 응답하고 있어요.", question);
        return new ChatQueryResponseDto(mockAnswer, mockProducts, true);
    }
}