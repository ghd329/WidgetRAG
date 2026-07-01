package com.widgetrag.backend.chat.repository;

import com.widgetrag.backend.chat.entity.ChatLog;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface ChatLogRepository extends JpaRepository<ChatLog, Long> {

    List<ChatLog> findByCompany_IdOrderByCreatedAtDesc(Long companyId);

    long countByCompany_Id(Long companyId);

    long countByCompany_IdAndAnswerIsNotNull(Long companyId);
}