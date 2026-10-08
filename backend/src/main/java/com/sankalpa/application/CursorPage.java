package com.sankalpa.application;
import com.sankalpa.domain.Session;
import java.util.List;
public record CursorPage(List<Session> content, boolean hasMore) {
    public CursorPage { content = List.copyOf(content); }
}
