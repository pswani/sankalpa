package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.adapter.in.conversation.AGUIModels;
import com.sankalpa.adapter.out.llm.ScriptedConversationModel;
import com.sankalpa.application.conversation.*;
import com.sankalpa.application.SankalpaUseCases;
import com.sankalpa.domain.ActionType;
import com.sankalpa.domain.commitment.PeriodUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.LocalDate;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.asyncDispatch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest(properties = {
        "sankalpa.assistant.enabled=true",
        "sankalpa.assistant.provider=fake",
        "spring.datasource.hikari.maximum-pool-size=4"
})
@ActiveProfiles("test")
@AutoConfigureMockMvc
class ConversationIntegrationTest {
    @Autowired ConversationUseCases proposals;
    @Autowired ScriptedConversationModel model;
    @Autowired JdbcTemplate jdbc;
    @Autowired MockMvc mvc;
    @Autowired SankalpaUseCases sankalpas;
    @Autowired ConversationCoordinator coordinator;
    @Autowired ConversationContextLoader contexts;
    @Autowired ConversationToolExecutor tools;
    @Autowired ObjectMapper json;

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM assistant_proposal");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM session_identity");
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM sankalpa");
    }

    @Test
    void modelToolSchemasSatisfyStrictJsonSchemaRequirements() throws Exception {
        for (var definition : tools.definitions(List.of("navigate_to_sankalpa", "open_sankalpa_list"))) {
            JsonNode schema = json.readTree(definition.inputSchema());
            assertThat(schema.path("type").asText()).isEqualTo("object");
            assertThat(schema.path("additionalProperties").asBoolean()).isFalse();
            Set<String> required = new HashSet<>();
            schema.path("required").forEach(value -> required.add(value.asText()));
            Set<String> properties = new HashSet<>();
            schema.path("properties").fieldNames().forEachRemaining(properties::add);
            assertThat(required).as(definition.name()).isEqualTo(properties);
            assertCompleteArraySchemas(schema);
        }
    }

    private static void assertCompleteArraySchemas(JsonNode node) {
        if (node.isObject()) {
            if ("array".equals(node.path("type").asText())) assertThat(node.has("items")).isTrue();
            node.elements().forEachRemaining(ConversationIntegrationTest::assertCompleteArraySchemas);
        } else if (node.isArray()) {
            node.elements().forEachRemaining(ConversationIntegrationTest::assertCompleteArraySchemas);
        }
    }

    @Test
    void declarationConfirmationIsAtomicAndReplaySafe() {
        UUID thread = UUID.randomUUID();
        Proposal proposal = declaration(thread, UUID.randomUUID());
        assertThat(count("sankalpa")).isZero();

        UUID confirmation = UUID.randomUUID();
        var first = proposals.confirm(thread, proposal.id(), confirmation);
        var replay = proposals.confirm(thread, proposal.id(), confirmation);

        assertThat(first.proposal().status()).isEqualTo(Proposal.Status.EXECUTED);
        assertThat(replay.replay()).isTrue();
        assertThat(replay.proposal().resultResourceId()).isEqualTo(first.proposal().resultResourceId());
        assertThat(count("sankalpa")).isEqualTo(1);
    }

    @Test
    void concurrentConfirmationCreatesExactlyOneDeclaration() throws Exception {
        UUID thread = UUID.randomUUID();
        Proposal proposal = declaration(thread, UUID.randomUUID());
        UUID confirmation = UUID.randomUUID();
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var one = pool.submit(() -> { start.await(); return proposals.confirm(thread, proposal.id(), confirmation); });
            var two = pool.submit(() -> { start.await(); return proposals.confirm(thread, proposal.id(), confirmation); });
            start.countDown(); one.get(); two.get();
        }
        assertThat(count("sankalpa")).isEqualTo(1);
    }

    @Test
    void cancellationAndProposalRunReplayAreStable() {
        UUID thread = UUID.randomUUID(); UUID run = UUID.randomUUID();
        Proposal original = declaration(thread, run);
        assertThat(proposals.findBySourceRunId(run).id()).isEqualTo(original.id());
        assertThat(proposals.cancel(thread, original.id()).replay()).isFalse();
        assertThat(proposals.cancel(thread, original.id()).replay()).isTrue();
        assertThat(count("sankalpa")).isZero();
    }

    @Test
    void multipleModelToolRequestsExecuteNothingAndStreamSafeError() throws Exception {
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(
                new ConversationModel.ToolCall("one", "propose_declare_sankalpa", "{}"),
                new ConversationModel.ToolCall("two", "open_sankalpa_list", "{}"))));
        String thread = UUID.randomUUID().toString(); String run = UUID.randomUUID().toString();
        String message = UUID.randomUUID().toString();
        String body = """
                {"threadId":"%s","runId":"%s","state":{},
                 "messages":[{"id":"%s","role":"user","content":"Declare meditation"}],
                 "tools":[],"context":[],"forwardedProps":{}}
                """.formatted(thread, run, message);
        var pending = mvc.perform(post("/api/v1/assistant/runs")
                        .contentType("application/json").accept("text/event-stream").content(body))
                .andExpect(request().asyncStarted()).andReturn();
        mvc.perform(asyncDispatch(pending)).andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("text/event-stream"))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("RUN_STARTED")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("ASSISTANT_COULD_NOT_INTERPRET")));
        assertThat(count("assistant_proposal")).isZero();
        assertThat(count("sankalpa")).isZero();
    }

    @Test
    void repeatedProposalRunReusesInterruptAndMessageIdentifiers() throws Exception {
        UUID thread = UUID.randomUUID(); UUID run = UUID.randomUUID();
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall(
                "one", "propose_declare_sankalpa", """
                {"title":"Meditate","description":"Sit daily","actionType":"MEDITATION",
                "startDate":"%s","periodUnit":"DAY","timesPerPeriod":1,
                "periodCount":null,"inferredFields":["startDate"]}
                """.formatted(LocalDate.now())))));
        String first = stream(thread, run);
        String second = stream(thread, run);
        String proposalId = jdbc.queryForObject("SELECT proposal_id FROM assistant_proposal", String.class);
        assertThat(first).contains(proposalId);
        assertThat(second).contains(proposalId);
        assertThat(second).isEqualTo(first);
        assertThat(count("assistant_proposal")).isEqualTo(1);
    }

    @Test
    void confirmedSessionUsesStableIdentityAndReplayDoesNotDuplicateIt() {
        var sankalpa = sankalpas.declare("Evening meditation", "Sit", ActionType.MEDITATION,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        sankalpas.begin(sankalpa.id(), null);
        UUID thread = UUID.randomUUID();
        Proposal proposal = proposals.proposeSession(thread, UUID.randomUUID(), sankalpa.id(),
                java.time.LocalDateTime.now(java.time.ZoneOffset.UTC), "Evening sit", List.of());
        UUID confirmation = UUID.randomUUID();

        var first = proposals.confirm(thread, proposal.id(), confirmation);
        var replay = proposals.confirm(thread, proposal.id(), confirmation);

        assertThat(replay.replay()).isTrue();
        assertThat(first.proposal().resultResourceId())
                .isEqualTo(((Proposal.LogSessionPayload) proposal.payload()).sessionId().value());
        assertThat(count("practice_session")).isEqualTo(1);
    }

    @Test
    void confirmedSessionNavigatesToItsSankalpaRatherThanItsSession() {
        var sankalpa = sankalpas.declare("Evening meditation", "Sit", ActionType.MEDITATION,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        sankalpas.begin(sankalpa.id(), null);
        UUID thread = UUID.randomUUID();
        Proposal proposal = proposals.proposeSession(thread, UUID.randomUUID(), sankalpa.id(),
                java.time.LocalDateTime.now(java.time.ZoneOffset.UTC), "Evening sit", List.of());

        var result = coordinator.run(new ConversationCoordinator.RunInput(thread, UUID.randomUUID(),
                List.of(), List.of("refresh_practice", "navigate_to_sankalpa"),
                new ConversationCoordinator.Resume(proposal.id(), false, UUID.randomUUID())));

        assertThat(result.effects()).extracting(ConversationCoordinator.Effect::name)
                .containsExactly("refresh_practice", "navigate_to_sankalpa");
        assertThat(result.effects().get(1).argumentsJson())
                .isEqualTo("{\"sankalpaId\":\"" + sankalpa.id() + "\"}");
        assertThat(result.resourceId())
                .isEqualTo(((Proposal.LogSessionPayload) proposal.payload()).sessionId().value());
    }

    @Test
    void offsetTimestampFromModelCreatesLocalSessionProposal() {
        var sankalpa = sankalpas.declare("Gym", "Workout", ActionType.PHYSICAL_ACTIVITY,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        var occurredAt = java.time.OffsetDateTime.now(java.time.ZoneOffset.UTC)
                .minusMinutes(1).withNano(0);
        sankalpas.begin(sankalpa.id(), occurredAt.toLocalDateTime().minusHours(1));
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall(
                "log", "propose_log_session", """
                {"sankalpaId":"%s","occurredAt":"%s","userSummary":"Gym session",
                 "alternativeSankalpaIds":[]}
                """.formatted(sankalpa.id(), occurredAt)))));

        var result = coordinator.run(new ConversationCoordinator.RunInput(UUID.randomUUID(),
                UUID.randomUUID(), List.of(new ConversationModel.Message("user", "Gym at 7 PM")),
                List.of(), null));

        assertThat(result.proposal()).isNotNull();
        assertThat(((Proposal.LogSessionPayload) result.proposal().payload()).occurredAt())
                .isEqualTo(occurredAt.toLocalDateTime());
    }

    @Test
    void ordinaryInputIsRejectedWhileThreadHasPendingProposal() {
        UUID thread = UUID.randomUUID();
        declaration(thread, UUID.randomUUID());
        var input = new ConversationCoordinator.RunInput(thread, UUID.randomUUID(),
                List.of(new ConversationModel.Message("user", "Change it")), List.of(), null);

        org.assertj.core.api.Assertions.assertThatThrownBy(() -> coordinator.run(input))
                .isInstanceOf(ConversationFailure.class)
                .hasMessageContaining("Confirm or cancel");
        assertThat(count("sankalpa")).isZero();
    }

    @Test
    void declarationLimitsAndStoredDescriptionTruncationFailClosed() {
        UUID thread = UUID.randomUUID();
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> proposals.proposeDeclaration(
                thread, UUID.randomUUID(), "x".repeat(201), "", ActionType.MEDITATION,
                LocalDate.now(), PeriodUnit.DAY, 1, null, List.of()))
                .isInstanceOf(RuntimeException.class);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> proposals.proposeDeclaration(
                thread, UUID.randomUUID(), "Valid", "x".repeat(2001), ActionType.MEDITATION,
                LocalDate.now(), PeriodUnit.DAY, 1, null, List.of()))
                .isInstanceOf(ConversationFailure.class);
        assertThat(count("assistant_proposal")).isZero();

        sankalpas.declare("Long description", "x".repeat(501), ActionType.OBSERVANCE,
                LocalDate.now(), PeriodUnit.DAY, 1, null);
        var summary = contexts.load().sankalpas().getFirst();
        assertThat(summary.description()).hasSize(500);
        assertThat(summary.descriptionTruncated()).isTrue();
    }

    @Test
    void failureRecordingExecutedStatusRollsBackDomainMutation() {
        UUID thread = UUID.randomUUID();
        Proposal proposal = declaration(thread, UUID.randomUUID());
        jdbc.execute("ALTER TABLE assistant_proposal ADD CONSTRAINT test_pending_only CHECK (status = 'PENDING')");
        try {
            org.assertj.core.api.Assertions.assertThatThrownBy(() ->
                    proposals.confirm(thread, proposal.id(), UUID.randomUUID()))
                    .isInstanceOf(RuntimeException.class);
            assertThat(count("sankalpa")).isZero();
            assertThat(jdbc.queryForObject(
                    "SELECT status FROM assistant_proposal WHERE proposal_id = ?", String.class,
                    proposal.id().toString())).isEqualTo("PENDING");
        } finally {
            jdbc.execute("ALTER TABLE assistant_proposal DROP CONSTRAINT test_pending_only");
        }
    }

    @Test
    void malformedToolGetsOneBoundedRepairRoundWithoutWriting() {
        model.enqueue(new ConversationModel.ToolRequestsTurn(List.of(new ConversationModel.ToolCall(
                "bad", "propose_declare_sankalpa", "{not-json"))));
        model.enqueue(new ConversationModel.TextTurn("What start date should I use?"));
        var result = coordinator.run(new ConversationCoordinator.RunInput(UUID.randomUUID(),
                UUID.randomUUID(), List.of(new ConversationModel.Message("user", "Declare one")),
                List.of(), null));

        assertThat(result.messages().getFirst().text()).contains("start date");
        assertThat(count("assistant_proposal")).isZero();
        assertThat(count("sankalpa")).isZero();
    }

    @Test
    void pinnedConfirmationFixtureMatchesServerProfile() throws Exception {
        try (var input = getClass().getResourceAsStream("/agui/confirmation-request.json")) {
            var request = json.readValue(input, AGUIModels.RunAgentInput.class);
            assertThat(request.state()).isEmpty();
            assertThat(request.context()).isEmpty();
            assertThat(request.messages()).isEmpty();
            assertThat(request.resume()).singleElement()
                    .satisfies(resume -> {
                        assertThat(resume.status()).isEqualTo("resolved");
                        assertThat(resume.payload().path("decision").asText()).isEqualTo("confirm");
                    });
        }
    }

    private String stream(UUID thread, UUID run) throws Exception {
        String body = """
                {"threadId":"%s","runId":"%s","state":{},
                 "messages":[{"id":"%s","role":"user","content":"Declare meditation"}],
                 "tools":[],"context":[],"forwardedProps":{}}
                """.formatted(thread, run, UUID.randomUUID());
        var pending = mvc.perform(post("/api/v1/assistant/runs")
                        .contentType("application/json").accept("text/event-stream").content(body))
                .andExpect(request().asyncStarted()).andReturn();
        return mvc.perform(asyncDispatch(pending)).andReturn().getResponse().getContentAsString();
    }

    private Proposal declaration(UUID thread, UUID run) {
        return proposals.proposeDeclaration(thread, run, "Meditate", "Sit daily",
                ActionType.MEDITATION, LocalDate.now(), PeriodUnit.DAY, 1, null,
                List.of("startDate"));
    }

    private int count(String table) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class);
    }
}
