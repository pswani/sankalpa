package com.sankalpa.adapter.in.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.application.*;
import com.sankalpa.domain.*;
import org.springframework.stereotype.Component;
import java.time.*;
import java.util.*;

@Component
public final class SessionCursorCodec {
    public record Cursor(int version, UUID serviceInstanceId, String revision, UUID target,
                         LocalDate from, LocalDate until, LocalDateTime occurredAt, UUID id) {}
    private final ObjectMapper mapper;
    public SessionCursorCodec(ObjectMapper mapper) { this.mapper=mapper; }
    public Cursor decode(String text, UUID instance, SankalpaId target, LocalDate from, LocalDate until) {
        if (text == null) return null;
        try {
            if (text.length() > 4096) throw new IllegalArgumentException();
            Cursor c=mapper.readValue(Base64.getUrlDecoder().decode(text),Cursor.class);
            if (c.version()!=1 || !instance.equals(c.serviceInstanceId())
                    || !Objects.equals(c.target(),target==null?null:target.value())
                    || !Objects.equals(from,c.from()) || !Objects.equals(until,c.until())
                    || c.occurredAt()==null || c.id()==null || c.revision()==null || !c.revision().matches("[0-9]+") || Long.parseLong(c.revision())<0) throw new IllegalArgumentException();
            return c;
        } catch(Exception failure) { throw new PracticeException("INVALID_SESSION_CURSOR", "Invalid or incompatible session cursor"); }
    }
    public String encode(UUID instance,long revision,SankalpaId target,LocalDate from,LocalDate until,Session last) {
        try { return Base64.getUrlEncoder().withoutPadding().encodeToString(mapper.writeValueAsBytes(
                new Cursor(1,instance,Long.toString(revision),target==null?null:target.value(),from,until,last.occurredAt(),last.id().value()))); }
        catch(Exception failure) {throw new IllegalStateException("Could not encode cursor",failure);}
    }
}
