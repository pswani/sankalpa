package com.sankalpa.application;
import com.sankalpa.domain.*;
import java.util.*;

public final class SessionContributions {
    private SessionContributions() {}
    public static boolean contributes(Session session, Sankalpa target, Map<SankalpaId, Sankalpa> owners) {
        Sankalpa owner = owners.get(session.sankalpaId());
        if (owner == null) throw new IllegalStateException("Session owner is missing");
        return owner.seriesId().equals(target.seriesId()) && target.acceptsPerformedAt(session.occurredAt());
    }
    public static Map<SankalpaId, Sankalpa> owners(List<Sankalpa> members) {
        Map<SankalpaId, Sankalpa> result = new LinkedHashMap<>();
        for (Sankalpa member : members) if (result.put(member.id(), member) != null)
            throw new IllegalStateException("Duplicate vow identity");
        return result;
    }
}
