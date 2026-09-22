package com.sankalpa.application;

import java.util.List;

public record PageResult<T>(
        List<T> content,
        int page,
        int size,
        long totalElements,
        long totalPages
) {
    public PageResult {
        content = List.copyOf(content);
    }
}
