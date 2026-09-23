package com.sankalpa.application;

import com.sankalpa.domain.Session;

/** Whether a session command created a row or replayed an already accepted command. */
public record SessionLogResult(Session session, boolean created) {}
