package com.widgetrag.backend.chat.controller;

import com.widgetrag.backend.chat.dto.ChatLogResponseDto;
import com.widgetrag.backend.chat.entity.ChatLog;
import com.widgetrag.backend.chat.repository.ChatLogRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/chat-logs")
@RequiredArgsConstructor
public class ChatLogController {

    private final ChatLogRepository chatLogRepository;

    @GetMapping
    public ResponseEntity<List<ChatLogResponseDto>> list(HttpServletRequest httpRequest) {
        Long companyId = requireCompanyId(httpRequest);

        List<ChatLogResponseDto> result = chatLogRepository
                .findByCompany_IdOrderByCreatedAtDesc(companyId)
                .stream()
                .map(log -> new ChatLogResponseDto(
                        log.getId(),
                        log.getQuestion(),
                        log.getAnswer(),
                        log.isFallback(),
                        log.getCreatedAt()
                ))
                .toList();

        return ResponseEntity.ok(result);
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(
            @PathVariable Long id,
            HttpServletRequest httpRequest
    ) {
        Long companyId = requireCompanyId(httpRequest);

        ChatLog log = chatLogRepository.findById(id)
                .orElseThrow(() -> new IllegalArgumentException("존재하지 않는 기록입니다."));

        if (!log.getCompany().getId().equals(companyId)) {
            throw new IllegalStateException("다른 회사의 기록은 삭제할 수 없습니다.");
        }

        chatLogRepository.delete(log);
        return ResponseEntity.noContent().build();
    }

    private Long requireCompanyId(HttpServletRequest httpRequest) {
        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("companyId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }
        return (Long) session.getAttribute("companyId");
    }
}