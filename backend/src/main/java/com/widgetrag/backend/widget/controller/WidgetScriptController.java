package com.widgetrag.backend.widget.controller;

import com.widgetrag.backend.company.entity.Company;
import com.widgetrag.backend.company.repository.CompanyRepository;
import com.widgetrag.backend.widget.dto.WidgetScriptResponseDto;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpSession;
import org.springframework.beans.factory.annotation.Value; // 수정
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/widget")
public class WidgetScriptController {

    private final CompanyRepository companyRepository;
    private final String widgetJsUrl;

    public WidgetScriptController(CompanyRepository companyRepository,
                                  @Value("${widget.script-base-url}") String widgetJsUrl) {
        this.companyRepository = companyRepository;
        this.widgetJsUrl = widgetJsUrl;
    }

    @GetMapping("/script")
    public ResponseEntity<WidgetScriptResponseDto> getEmbedScript(HttpServletRequest httpRequest) {

        HttpSession session = httpRequest.getSession(false);
        if (session == null || session.getAttribute("companyId") == null) {
            throw new IllegalStateException("로그인이 필요합니다.");
        }

        Long companyId = (Long) session.getAttribute("companyId");

        Company company = companyRepository.findById(companyId)
                .orElseThrow(() -> new IllegalStateException("회사 정보를 찾을 수 없습니다."));

        String embedCode = String.format(
                "<script src=\"%s\" data-client-code=\"%s\"></script>",
                widgetJsUrl, company.getClientCode()
        );

        return ResponseEntity.ok(new WidgetScriptResponseDto(embedCode, company.getClientCode()));
    }
}