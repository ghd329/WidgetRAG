package com.widgetrag.backend.chat.service;

import com.widgetrag.backend.chat.dto.ChatQueryRequestDto;
import com.widgetrag.backend.chat.dto.ChatQueryResponseDto;
import com.widgetrag.backend.chat.dto.RetrievedProductDto;
import com.widgetrag.backend.chat.entity.ChatLog;
import com.widgetrag.backend.chat.exception.InvalidClientCodeException;
import com.widgetrag.backend.chat.repository.ChatLogRepository;
import com.widgetrag.backend.company.entity.Company;
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
    private final ChatLogRepository chatLogRepository; // ▼▼▼ 추가 ▼▼▼

    public ChatQueryResponseDto getAnswer(ChatQueryRequestDto request) {

        // ▼▼▼ existsByClientCode → findByClientCode로 변경 (company 엔티티 필요) ▼▼▼
        Company company = companyRepository.findByClientCode(request.clientCode())
                .orElseThrow(() -> new InvalidClientCodeException(request.clientCode()));
        // ▲▲▲ existsByClientCode → findByClientCode로 변경 ▲▲▲

        List<SearchedProductDto> searchResults = openSearchIndexService.search(
                request.clientCode(), request.question());

        ChatQueryResponseDto response;

        // 모델정의서 3.6 Fallback 정책 - 검색 결과 0건이면 목업으로 대체
        if (searchResults.isEmpty()) {
            response = buildFallbackResponse(request.question());
        } else {
            List<RetrievedProductDto> products = searchResults.stream()
                    .map(p -> new RetrievedProductDto(
                            p.productItemId(),
                            p.productName(),
                            p.price(),
                            String.join(", ", p.categories()),
                            p.productUrl()
                    ))
                    .toList();

            try {
                String answer = aiServerClient.generate(request.clientCode(), request.question(), products);
                response = new ChatQueryResponseDto(answer, products, false);
            } catch (RestClientException e) {
                // 모델정의서 3.6 Fallback 정책 - GPU 서버 응답 지연/실패 시 목업으로 대체
                response = buildFallbackResponse(request.question());
            }
        }

        // ▼▼▼ 회사별로 DB에 질문/답변 기록 저장 ▼▼▼
        saveChatLog(company, request.question(), response);
        // ▲▲▲ 회사별로 DB에 질문/답변 기록 저장 ▲▲▲

        return response;
    }

    private void saveChatLog(Company company, String question, ChatQueryResponseDto response) {
        ChatLog log = ChatLog.builder()
                .company(company)
                .question(question)
                .answer(response.answer())
                .isFallback(response.isFallback())
                .build();

        chatLogRepository.save(log);
    }

    private ChatQueryResponseDto buildFallbackResponse(String question) {
        List<RetrievedProductDto> mockProducts = List.of(
                new RetrievedProductDto(null, "린넨 셔츠", 29900, "셔츠/블라우스", null)
        );
        String mockAnswer = String.format(
                "'%s'에 대한 검색 결과가 없어 예시 데이터로 응답하고 있어요.", question);
        return new ChatQueryResponseDto(mockAnswer, mockProducts, true);
    }
}