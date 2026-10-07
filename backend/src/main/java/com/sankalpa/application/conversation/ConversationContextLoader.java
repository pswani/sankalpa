package com.sankalpa.application.conversation;

import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.application.port.SankalpaClock;

import java.time.ZoneId;

public final class ConversationContextLoader {
    public static final int MAX_CATALOG = 200;
    public static final int DESCRIPTION_SNIPPET = 500;
    private final SankalpaUseCases sankalpas;
    private final SankalpaClock clock;
    private final ZoneId zone;

    public ConversationContextLoader(SankalpaUseCases sankalpas, SankalpaClock clock, ZoneId zone) {
        this.sankalpas = sankalpas;
        this.clock = clock;
        this.zone = zone;
    }

    public ConversationModel.Context load() {
        var all = sankalpas.list();
        if (all.size() > MAX_CATALOG) {
            throw new ConversationFailure("ASSISTANT_LIMIT_REACHED", "Sankalpa catalog is too large");
        }
        var summaries = all.stream().map(s -> {
            String description = s.description().value();
            boolean truncated = description.length() > DESCRIPTION_SNIPPET;
            if (truncated) description = description.substring(0, DESCRIPTION_SNIPPET);
            return new ConversationModel.SankalpaSummary(s.id().toString(), s.title().value(),
                    description, truncated, s.actionType().name(), s.lifecycle().current().name(),
                    s.commitment().startDate().toString(),
                    s.commitment().endDate().map(Object::toString).orElse(null),
                    s.commitment().periodUnit().name(), s.commitment().timesPerPeriod());
        }).toList();
        return new ConversationModel.Context(clock.now().toString(), zone.getId(), summaries);
    }
}
