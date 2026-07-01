package com.widgetrag.backend.chat.entity;

import com.widgetrag.backend.company.entity.Company;
import jakarta.persistence.*;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;

@Entity
@Table(name = "chat_log")
@Getter
@NoArgsConstructor
public class ChatLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "company_id", nullable = false)
    private Company company;

    @Column(nullable = false, columnDefinition = "TEXT")
    private String question;

    @Column(columnDefinition = "TEXT")
    private String answer;

    @Column(name = "is_fallback", nullable = false)
    private boolean isFallback;

    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;

    @Builder
    public ChatLog(Company company, String question, String answer, boolean isFallback) {
        this.company = company;
        this.question = question;
        this.answer = answer;
        this.isFallback = isFallback;
    }
}