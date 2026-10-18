package com.sankalpa.adapter.in.web;

import com.sankalpa.application.*;
import com.sankalpa.domain.*;
import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import org.springframework.http.*;
import org.springframework.stereotype.Component;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import static com.sankalpa.adapter.in.web.ApiModels.*;

/** Request contract and same-transaction response assembly, with no thread-local request state. */
@Component
public final class PracticeHttp {
    private final SankalpaUseCases service;
    private final ServiceInstanceIdentity identity;
    private final SessionCursorCodec cursors;
    public PracticeHttp(SankalpaUseCases service,ServiceInstanceIdentity identity,SessionCursorCodec cursors) {
        this.service=service;this.identity=identity;this.cursors=cursors;
    }
    public void requireInstance(HttpHeaders headers) {
        String value = headers.getFirst("Sankalpa-Service-Instance");
        identity.require(value == null ? null : UUID.fromString(value));
    }
    public PracticeContract contract(HttpHeaders headers) {
        String version=headers.getFirst("Linked-Sankalpa-Version");
        if(version==null)return PracticeContract.SINGLE_VOW_V1;
        if(!version.equals("1"))throw new PracticeException("LINKED_SANKALPA_UPGRADE_REQUIRED","Linked contract version 1 is required");
        String instance=headers.getFirst("Sankalpa-Service-Instance");
        identity.require(instance==null?null:UUID.fromString(instance));
        return PracticeContract.LINKED_V1;
    }
    public <T> ResponseEntity<T> read(HttpHeaders headers,Supplier<T> query) {
        contract(headers);
        return response(service.readSnapshot(revision(headers),query),200);
    }
    public <T> ResponseEntity<T> write(HttpHeaders headers,Supplier<T> query,int status) {
        contract(headers);
        return response(service.writeSnapshot(query),status);
    }
    public <T> ResponseEntity<T> response(PracticeSnapshot<T> snapshot,int status) {
        return ResponseEntity.status(status).header("Sankalpa-Service-Instance",identity.value().toString())
                .header("Sankalpa-Practice-Revision",Long.toString(snapshot.revision())).body(snapshot.value());
    }
    private Long revision(HttpHeaders headers) {
        String text=headers.getFirst("Sankalpa-Practice-Revision");
        if(text==null)return null;
        if(!text.matches("[0-9]+"))throw new IllegalArgumentException("Invalid revision");
        return Long.parseLong(text);
    }
    public SankalpaResponse vow(Sankalpa value) {
        return vows(List.of(value)).getFirst();
    }
    public List<SankalpaResponse> vows(List<Sankalpa> values) {
        var counts = service.totalSessionCounts(values);
        var children = new HashMap<SankalpaId, SankalpaId>();
        var roots = new HashSet<SankalpaId>();
        for (var value : values) {
            if (roots.add(value.seriesId())) {
                service.linkedSeries(value.id(), PracticeContract.LINKED_V1).forEach(v ->
                        v.extensionOf().ifPresent(source -> children.put(source, v.id())));
            }
        }
        return values.stream().map(value -> new SankalpaResponse(value.id().value(), value.title().value(),
                value.description().value(), value.actionType(), value.commitment().startDate(),
                value.commitment().endDate().orElse(null), value.commitment().periodUnit(),
                value.commitment().timesPerPeriod(), value.commitment().periodCount(), value.lifecycle().current(),
                value.declaredAt(), value.seriesId().value(), value.extensionOf().map(SankalpaId::value).orElse(null),
                Optional.ofNullable(children.get(value.id())).map(SankalpaId::value).orElse(null), counts.get(value.id()))).toList();
    }
    public SessionResponse session(Session value) {
        return sessions(List.of(value)).getFirst();
    }
    public List<SessionResponse> sessions(List<Session> values) {
        var contributors = service.contributors(values);
        return values.stream().map(value -> new SessionResponse(value.id().value(), value.sankalpaId().value(),
                value.occurredAt(), value.loggedAt(), value.sankalpaId().value(),
                contributors.get(value.id()).stream().map(SankalpaId::value).toList())).toList();
    }
    public List<LifecycleTransitionResponse> history(Sankalpa value) {
        var entries=value.lifecycle().transitions();
        return java.util.stream.IntStream.range(0,entries.size()).mapToObj(i -> {
            var t=entries.get(i);return new LifecycleTransitionResponse(t.from(),t.to(),t.effectiveAt(),t.recordedAt(),
                    t.originSankalpaId().value(),i);
        }).toList();
    }
    public List<VowSnapshot> series(SankalpaId id) {
        var members = service.linkedSeries(id, PracticeContract.LINKED_V1);
        var responses = vows(members);
        return java.util.stream.IntStream.range(0, members.size())
                .mapToObj(i -> new VowSnapshot(responses.get(i), history(members.get(i)))).toList();
    }
    public ResponseEntity<CursorSessionPageResponse> page(HttpHeaders headers,SankalpaId target,
            LocalDate from,LocalDate until,String token,int size) {
        contract(headers).requireLinked();
        var cursor=cursors.decode(token,identity.value(),target,from,until);
        Long required=revision(headers);
        if(cursor!=null) {
            long cr=Long.parseLong(cursor.revision());
            if(required!=null && required!=cr)throw new PracticeException("INVALID_SESSION_CURSOR","Cursor and request revisions differ");
            required=cr;
        }
        var snapshot=service.readSnapshot(required,()-> {
            var result=service.readSnapshot(null,()->service.cursorSessions(target,from,until,cursor==null?null:
                    new SessionBoundary(cursor.occurredAt(),new SessionId(cursor.id())),size,PracticeContract.LINKED_V1));
            String next=result.value().hasMore()?cursors.encode(identity.value(),result.revision(),target,from,until,result.value().content().getLast()):null;
            return new CursorSessionPageResponse(sessions(result.value().content()),next,result.value().hasMore());
        });
        return response(snapshot,200);
    }
}
