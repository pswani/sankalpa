package com.sankalpa.application;

import com.sankalpa.domain.*;
import com.sankalpa.domain.lifecycle.*;
import java.util.*;

/** Cross-record invariants for loading a persisted collection. */
public final class PracticeValidation {
    private PracticeValidation() {}
    public static void validate(List<Sankalpa> vows, List<Session> facts) {
        var byId=SessionContributions.owners(vows);
        Set<SankalpaId> sources=new HashSet<>();
        for(Sankalpa v:vows) {
            require(byId.containsKey(v.seriesId()),"Missing series root");
            Sankalpa root=byId.get(v.seriesId());
            require(root.extensionOf().isEmpty() && root.seriesId().equals(root.id()),"Invalid series root");
            var history=v.lifecycle().transitions();
            LifecycleState state=LifecycleState.NOT_STARTED;
            java.time.LocalDateTime recorded=null,effective=null;
            for(var t:history) {
                require(t.originSankalpaId()!=null && byId.containsKey(t.originSankalpaId()),"Missing transition origin");
                require(t.from()==state && state.canTransitionTo(t.to()),"Invalid lifecycle sequence");
                require(recorded==null || !t.recordedAt().isBefore(recorded),"Audit time moved backwards");
                require(effective==null || !t.effectiveAt().isBefore(effective),"Lifecycle time moved backwards");
                boolean begin=t.from()==LifecycleState.NOT_STARTED && t.to()==LifecycleState.IN_PROGRESS;
                require(begin ? !t.effectiveAt().isAfter(t.recordedAt()) && !t.effectiveAt().toLocalDate().isBefore(v.commitment().startDate())
                        : t.effectiveAt().equals(t.recordedAt()),"Invalid transition timing");
                state=t.to(); recorded=t.recordedAt(); effective=t.effectiveAt();
            }
            require(state==v.lifecycle().current(),"State differs from audit");
            if(v.extensionOf().isEmpty()) {
                require(v.id().equals(v.seriesId()),"Original is not its own root");
                require(history.stream().allMatch(t->v.id().equals(t.originSankalpaId()) && !t.recordedAt().isBefore(v.declaredAt())),"Original contains invalid audit");
                continue;
            }
            SankalpaId parentId=v.extensionOf().orElseThrow();
            require(sources.add(parentId),"Branched series");
            Sankalpa parent=byId.get(parentId);
            require(parent!=null && parent.seriesId().equals(v.seriesId()),"Missing or foreign source");
            Set<SankalpaId> ancestors=new HashSet<>();
            Sankalpa ancestor=parent;
            while(ancestor!=null) {
                require(ancestors.add(ancestor.id()) && !ancestor.id().equals(v.id()),"Cyclic series");
                ancestor=ancestor.extensionOf().map(byId::get).orElse(null);
            }
            require(ancestors.contains(root.id()),"Disconnected series");
            require(v.title().equals(parent.title()) && v.description().equals(parent.description())
                    && v.actionType()==parent.actionType() && v.commitment().startDate().equals(parent.commitment().startDate())
                    && v.commitment().periodUnit()==parent.commitment().periodUnit()
                    && v.commitment().timesPerPeriod()==parent.commitment().timesPerPeriod(),"Changed inherited practice");
            require(v.commitment().periodCount()!=null && parent.commitment().periodCount()!=null
                    && v.commitment().periodCount()>parent.commitment().periodCount(),"Duration did not increase");
            require(!v.declaredAt().isBefore(parent.declaredAt()),"Child predates source");
            int prefix=0;
            while(prefix<history.size() && !history.get(prefix).originSankalpaId().equals(v.id()))prefix++;
            var original=parent.lifecycle().transitions();
            require(prefix>0 && prefix<=original.size() && original.subList(0,prefix).equals(history.subList(0,prefix)),"Invalid inherited prefix");
            var inheritedState=history.get(prefix-1).to();
            require(inheritedState==LifecycleState.IN_PROGRESS || inheritedState==LifecycleState.PAUSED,"Invalid inherited state");
            for(int i=0;i<history.size();i++) {
                var t=history.get(i);
                require(i<prefix ? ancestors.contains(t.originSankalpaId()) && !t.recordedAt().isAfter(v.declaredAt())
                        : v.id().equals(t.originSankalpaId()) && !t.recordedAt().isBefore(v.declaredAt()),"Invalid history provenance");
            }
            require(original.stream().filter(t->t.recordedAt().isBefore(v.declaredAt())).count()<=prefix,"Missing inherited history");
        }
        Set<SessionId> ids=new HashSet<>();
        for(Session fact:facts) {
            require(ids.add(fact.id()),"Duplicate session identity");
            Sankalpa owner=byId.get(fact.sankalpaId());
            require(owner!=null && owner.acceptsPerformedAt(fact.occurredAt()),"Invalid session owner/eligibility");
            require(!fact.occurredAt().isAfter(fact.loggedAt()),"Session logged before performance");
        }
    }
    private static void require(boolean value,String message){if(!value)throw new IllegalStateException(message);}
}
