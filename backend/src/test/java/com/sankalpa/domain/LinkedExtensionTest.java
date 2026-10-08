package com.sankalpa.domain;
import com.sankalpa.domain.commitment.*;
import com.sankalpa.domain.lifecycle.*;
import org.junit.jupiter.api.Test;
import java.time.*;
import static org.assertj.core.api.Assertions.*;

class LinkedExtensionTest {
    Sankalpa source(LocalDate start,Integer count,PeriodUnit unit) {
        var vow=Sankalpa.declare(SankalpaId.newId(),new Title("Observe"),new Description(""),ActionType.OBSERVANCE,
                new Commitment(start,unit,1,count),start.atStartOfDay(),start);
        vow.begin(start.atStartOfDay(),start.atStartOfDay());return vow;
    }
    @Test void extensionInheritsOldStartButDeclarationLimitStillApplies() {
        var old=source(LocalDate.of(2024,7,1),40,PeriodUnit.DAY);
        var now=LocalDateTime.of(2026,10,7,12,0);
        var extended=old.extend(SankalpaId.newId(),900,now);
        assertThat(extended.commitment().startDate()).isEqualTo(old.commitment().startDate());
        assertThatThrownBy(()->Sankalpa.declare(SankalpaId.newId(),old.title(),old.description(),old.actionType(),old.commitment(),now,now.toLocalDate()))
                .isInstanceOf(DomainException.class).extracting("code").isEqualTo("START_DATE_TOO_FAR_IN_PAST");
    }
    @Test void finiteStateAndDurationRestrictions() {
        var start=LocalDate.of(2026,7,1);var source=source(start,40,PeriodUnit.DAY);
        assertThatThrownBy(()->source.extend(SankalpaId.newId(),40,start.atStartOfDay())).isInstanceOf(DomainException.class).extracting("code").isEqualTo("DURATION_NOT_GREATER");
        assertThatThrownBy(()->source.extend(SankalpaId.newId(),50,start.plusDays(60).atStartOfDay())).isInstanceOf(DomainException.class).extracting("code").isEqualTo("EXTENSION_ENDS_IN_PAST");
        assertThat(source.extend(SankalpaId.newId(),50,start.plusDays(49).atStartOfDay()).commitment().endDate()).contains(start.plusDays(49));
        source.stop(start.atStartOfDay());
        assertThatThrownBy(()->source.extend(SankalpaId.newId(),90,start.atStartOfDay())).isInstanceOf(DomainException.class).extracting("code").isEqualTo("SOURCE_NOT_EXTENDABLE");
        var indefinite=source(start,null,PeriodUnit.DAY);
        assertThatThrownBy(()->indefinite.extend(SankalpaId.newId(),90,start.atStartOfDay())).isInstanceOf(DomainException.class);
    }
    @Test void pausedTimelineIsACopyAndCalendarBoundariesStayAnchored() {
        var start=LocalDate.of(2026,1,31);var source=source(start,2,PeriodUnit.MONTH);
        source.pause(start.plusDays(1).atStartOfDay());
        var child=source.extend(SankalpaId.newId(),4,start.plusDays(2).atStartOfDay());
        assertThat(child.lifecycle().current()).isEqualTo(LifecycleState.PAUSED);
        assertThat(child.commitment().endDate()).contains(LocalDate.of(2026,5,30));
        source.resume(start.plusDays(3).atStartOfDay());
        assertThat(child.lifecycle().current()).isEqualTo(LifecycleState.PAUSED);
        assertThat(child.lifecycle().transitions()).hasSize(2).allMatch(t->t.originSankalpaId().equals(source.id()));
    }
    @Test void refusesUnstartedCompletedAndInvalidWholePeriodCounts() {
        var start = LocalDate.of(2026, 7, 1);
        var vow = Sankalpa.declare(SankalpaId.newId(), new Title("Observe"), new Description(""), ActionType.OBSERVANCE,
                new Commitment(start, PeriodUnit.DAY, 1, 40), start.atStartOfDay(), start);
        assertThatThrownBy(() -> vow.extend(SankalpaId.newId(), 90, start.atStartOfDay())).isInstanceOf(DomainException.class);
        vow.begin(start.atStartOfDay(), start.atStartOfDay());
        for (int count : new int[]{0, -1, 39, 3651}) {
            assertThatThrownBy(() -> vow.extend(SankalpaId.newId(), count, start.atStartOfDay())).isInstanceOf(DomainException.class);
        }
        vow.complete(CompletionOutcome.SUCCESSFUL, start.plusDays(40).atStartOfDay());
        assertThatThrownBy(() -> vow.extend(SankalpaId.newId(), 90, start.plusDays(40).atStartOfDay())).isInstanceOf(DomainException.class);
    }
    @Test void leapYearExtensionsStayAnchoredAndClockCannotRewriteAudit() {
        var start = LocalDate.of(2024, 2, 29);
        var vow = source(start, 1, PeriodUnit.YEAR);
        var child = vow.extend(SankalpaId.newId(), 2, start.plusDays(20).atStartOfDay());
        assertThat(child.commitment().endDate()).contains(LocalDate.of(2026, 2, 27));
        vow.pause(start.plusDays(30).atStartOfDay());
        assertThatThrownBy(() -> vow.resume(start.plusDays(29).atStartOfDay()))
                .isInstanceOf(DomainException.class).extracting("code").isEqualTo("TRANSITION_TIME_REGRESSION");
        assertThatThrownBy(() -> vow.extend(SankalpaId.newId(), 3, start.plusDays(29).atStartOfDay()))
                .isInstanceOf(DomainException.class).extracting("code").isEqualTo("TRANSITION_TIME_REGRESSION");
    }

}
