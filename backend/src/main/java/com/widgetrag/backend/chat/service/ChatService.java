package com.widgetrag.backend.chat.service;

import com.widgetrag.backend.chat.dto.ChatQueryRequestDto;
import com.widgetrag.backend.chat.dto.ChatQueryResponseDto;
import com.widgetrag.backend.chat.dto.RetrievedProductDto;
import com.widgetrag.backend.chat.exception.InvalidClientCodeException;
import com.widgetrag.backend.company.repository.CompanyRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
@RequiredArgsConstructor
public class ChatService {

    private final CompanyRepository companyRepository;

    public ChatQueryResponseDto getMockAnswer(ChatQueryRequestDto request) {

        // 존재하지 않는 상점 코드로 위젯이 위조되어 호출되는 경우 방지
        if (!companyRepository.existsByClientCode(request.clientCode())) {
            throw new InvalidClientCodeException(request.clientCode());
        }

        // 모델정의서 3.6 Fallback 정책 - 실제 RAG/LLM 연동 전까지는 항상 목업 응답
        List<RetrievedProductDto> mockProducts = List.of(
                new RetrievedProductDto("린넨 셔츠", 29900, "셔츠/블라우스"),
                new RetrievedProductDto("코튼 와이드 팬츠", 35000, "팬츠")
        );

        String mockAnswer = String.format(
                "'%s'에 대한 추천 상품입니다. 현재는 예시 데이터로 응답하고 있어요.",
                request.question()
        );

        return new ChatQueryResponseDto(mockAnswer, mockProducts, true);
    }
}