package com.sankalpa.adapter.in.web;

import com.sankalpa.application.ConcurrentModificationException;
import com.sankalpa.application.NotFoundException;
import com.sankalpa.domain.DomainException;
import jakarta.validation.ConstraintViolationException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.method.annotation.HandlerMethodValidationException;

import java.net.URI;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

@RestControllerAdvice
public class ApiExceptionHandler {
    private static final Set<String> REQUEST_ERROR_CODES = Set.of(
            "INVALID_DATE_RANGE", "INVALID_PAGINATION", "PERIOD_RANGE_TOO_LARGE");
    private static final Set<String> CONFLICT_ERROR_CODES = Set.of("IDEMPOTENCY_CONFLICT");

    @ExceptionHandler(NotFoundException.class)
    ResponseEntity<ProblemDetail> notFound(NotFoundException exception) {
        return problem(HttpStatus.NOT_FOUND, "SANKALPA_NOT_FOUND", exception.getMessage(), null);
    }

    @ExceptionHandler(DomainException.class)
    ResponseEntity<ProblemDetail> domain(DomainException exception) {
        HttpStatus status;
        if (REQUEST_ERROR_CODES.contains(exception.code())) status = HttpStatus.BAD_REQUEST;
        else if (CONFLICT_ERROR_CODES.contains(exception.code())) status = HttpStatus.CONFLICT;
        else status = HttpStatus.UNPROCESSABLE_ENTITY;
        return problem(status, exception.code(), exception.getMessage(), null);
    }

    @ExceptionHandler(ConcurrentModificationException.class)
    ResponseEntity<ProblemDetail> conflict(ConcurrentModificationException exception) {
        return problem(HttpStatus.CONFLICT, "CONCURRENT_MODIFICATION", exception.getMessage(), null);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    ResponseEntity<ProblemDetail> validation(MethodArgumentNotValidException exception) {
        Map<String, String> errors = exception.getBindingResult().getFieldErrors().stream()
                .collect(Collectors.toMap(error -> error.getField(), error -> error.getDefaultMessage(),
                        (first, ignored) -> first));
        return problem(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "Request validation failed", errors);
    }

    @ExceptionHandler({IllegalArgumentException.class, HttpMessageNotReadableException.class,
            MethodArgumentTypeMismatchException.class, MissingServletRequestParameterException.class,
            ConstraintViolationException.class, HandlerMethodValidationException.class})
    ResponseEntity<ProblemDetail> badRequest(Exception exception) {
        return problem(HttpStatus.BAD_REQUEST, "INVALID_REQUEST", "Request could not be parsed", null);
    }

    private ResponseEntity<ProblemDetail> problem(HttpStatus status, String code, String detail,
                                                   Map<String, String> errors) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setType(URI.create("urn:sankalpa:problem:" + code.toLowerCase()));
        problem.setTitle(status.getReasonPhrase());
        problem.setProperty("code", code);
        if (errors != null) problem.setProperty("errors", errors);
        return ResponseEntity.status(status).body(problem);
    }
}
