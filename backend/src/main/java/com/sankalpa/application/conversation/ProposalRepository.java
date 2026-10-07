package com.sankalpa.application.conversation;

import java.util.Optional;
import java.util.UUID;

public interface ProposalRepository {
    void insert(Proposal proposal);
    Optional<Proposal> findBySourceRunId(UUID sourceRunId);
    Optional<Proposal> findPendingByThread(UUID threadId);
    Optional<Proposal> findByIdForUpdate(UUID proposalId);
    void update(Proposal proposal);
}
