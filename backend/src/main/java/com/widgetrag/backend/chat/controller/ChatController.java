package com.widgetrag.backend.chat.controller;

import com.widgetrag.backend.chat.dto.ChatQueryRequestDto;
import com.widgetrag.backend.chat.dto.ChatQueryResponseDto;
import com.widgetrag.backend.chat.service.ChatService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/chat")
@RequiredArgsConstructor
@Tag(name = "챗봇 질의응답", description = "쇼핑몰 위젯의 챗봇 질의 응답 API (현재 목업 응답)")
public class ChatController {

    private final ChatService chatService;

    @Operation(
            summary = "챗봇 질의 (목업)",
            description = "쇼핑몰 위젯에서 상점 코드와 질문을 전송하면 추천 답변을 반환합니다. " +
                    "현재는 실제 RAG/LLM 연동 전 단계로, 항상 고정된 예시 데이터로 응답합니다(isFallback: true). " +
                    "유효하지 않은 상점 코드인 경우 400 에러가 반환됩니다."
    )
    @PostMapping
    public ResponseEntity<ChatQueryResponseDto> chat(@RequestBody ChatQueryRequestDto request) {
        ChatQueryResponseDto response = chatService.getAnswer(request); // 메서드명 변경
        return ResponseEntity.ok(response);
    }
}