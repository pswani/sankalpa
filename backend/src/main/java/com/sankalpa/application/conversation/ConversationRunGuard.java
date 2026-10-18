package com.sankalpa.application.conversation;

import java.util.function.Supplier;

/** Run ownership and provider usage policy; implementations do not execute domain actions. */
public interface ConversationRunGuard {
    default void beforeModel() {}
    <T> T run(ConversationCoordinator.RunInput input, Supplier<T> action);
}
