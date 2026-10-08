package com.sankalpa.application;
import java.time.LocalDateTime;
import com.sankalpa.domain.SessionId;
public record SessionBoundary(LocalDateTime occurredAt, SessionId id) {}
