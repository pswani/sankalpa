package com.sankalpa.adapter.in.web;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.*;
import org.springframework.format.annotation.DateTimeFormat;
import io.swagger.v3.oas.annotations.Operation;
import java.time.LocalDate;
import static com.sankalpa.adapter.in.web.ApiModels.*;

@RestController
@RequestMapping("/api/v1/sessions")
public final class JournalController {
    private final PracticeHttp http;
    public JournalController(PracticeHttp http){this.http=http;}
    @com.sankalpa.adapter.in.web.LinkedPracticeHeaders
    @GetMapping
    @Operation(summary="Get unique session facts with revision-bound cursor pagination")
    public ResponseEntity<CursorSessionPageResponse> sessions(@io.swagger.v3.oas.annotations.Parameter(hidden=true) @RequestHeader HttpHeaders headers,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate until,
            @RequestParam(required=false) String cursor,@RequestParam(defaultValue="100") int size) {
        return http.page(headers,null,from,until,cursor,size);
    }
}
