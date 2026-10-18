package com.sankalpa.adapter;
import com.sankalpa.application.conversation.*;
import org.junit.jupiter.api.Test;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
class BatchPlanTest {
    BatchSessionPlan range(String from,String through) { return new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE,LocalDate.parse(from),LocalDate.parse(through),LocalTime.of(20,0),null); }
    @Test void dailyExpansionUsesInclusiveCalendarDatesAcrossDstLeapAndMonthBoundaries() {
        assertThat(range("2026-09-14","2026-10-13").expand()).hasSize(30);
        assertThat(range("2024-02-28","2024-03-01").expand()).containsExactly(LocalDateTime.parse("2024-02-28T20:00"),LocalDateTime.parse("2024-02-29T20:00"),LocalDateTime.parse("2024-03-01T20:00"));
        assertThat(range("2026-10-31","2026-11-02").expand()).hasSize(3).allMatch(t->t.toLocalTime().equals(LocalTime.of(20,0)));
        assertThatThrownBy(()->range("2026-09-14","2026-10-17").expand()).isInstanceOfSatisfying(ConversationFailure.class,f->assertThat(f.code()).isEqualTo("BATCH_TOO_LARGE"));
    }
    @Test void missingAmbiguousAndDuplicatePlansFailClosed() {
        assertThatThrownBy(()->new BatchSessionPlan(null,null,null,null,null).expand()).isInstanceOf(ConversationFailure.class);
        assertThatThrownBy(()->range("2026-10-17","2026-09-14").expand()).isInstanceOf(ConversationFailure.class);
        assertThatThrownBy(()->new BatchSessionPlan(BatchSessionPlan.Mode.DAILY_RANGE,LocalDate.now(),LocalDate.now(),null,null).expand()).isInstanceOf(ConversationFailure.class);
        assertThatThrownBy(()->new BatchSessionPlan(BatchSessionPlan.Mode.EXPLICIT_TIMESTAMPS,null,null,null,List.of()).expand()).isInstanceOf(ConversationFailure.class);
    }
}
