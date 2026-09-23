package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sankalpa.application.port.SankalpaClock;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;

import java.time.LocalDate;
import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(ApiContractTest.FixedClockConfiguration.class)
class ApiContractTest {
    private static final LocalDateTime NOW = LocalDateTime.of(2026, 6, 15, 12, 0);

    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate jdbc;

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM practice_session");
        jdbc.update("DELETE FROM session_deletion_tombstone");
        jdbc.update("DELETE FROM sankalpa_lifecycle_transition");
        jdbc.update("DELETE FROM sankalpa");
    }

    @Test
    void openApiPublishesEveryRestContract() throws Exception {
        String body = mvc.perform(get("/v3/api-docs"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.info.title").value("Sankalpa REST API"))
                .andReturn().getResponse().getContentAsString();
        JsonNode paths = json.readTree(body).path("paths");
        assertThat(paths.has("/api/v1/sankalpas")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/begin")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/pause")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/resume")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/complete")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/stop")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/sessions")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/sessions/{sessionId}")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/lifecycle-history")).isTrue();
        assertThat(paths.has("/api/v1/sankalpas/{id}/period-outcomes")).isTrue();

        JsonNode document = json.readTree(body);
        JsonNode sessionGet = paths.path("/api/v1/sankalpas/{id}/sessions").path("get");
        assertThat(sessionGet.path("responses").has("200")).isTrue();
        assertThat(sessionGet.path("responses").has("400")).isTrue();
        assertThat(sessionGet.path("responses").has("404")).isTrue();
        assertThat(sessionGet.path("responses").has("422")).isFalse();
        assertThat(sessionGet.path("responses").path("200").path("content")
                .has(MediaType.APPLICATION_JSON_VALUE)).isTrue();
        assertThat(sessionGet.path("responses").path("400").path("content")
                .has(MediaType.APPLICATION_PROBLEM_JSON_VALUE)).isTrue();
        assertThat(hasParameter(sessionGet, "page")).isTrue();
        assertThat(hasParameter(sessionGet, "size")).isTrue();
        assertThat(hasParameter(paths.path("/api/v1/sankalpas/{id}/sessions").path("post"),
                "Idempotency-Key")).isTrue();

        JsonNode declareResponses = paths.path("/api/v1/sankalpas").path("post").path("responses");
        assertThat(declareResponses.has("201")).isTrue();
        assertThat(declareResponses.has("400")).isTrue();
        assertThat(declareResponses.has("409")).isTrue();
        assertThat(declareResponses.has("422")).isTrue();
        JsonNode schemas = document.path("components").path("schemas");
        assertThat(schemas.path("ApiProblem")
                .path("properties").has("code")).isTrue();
        assertThat(schemas.path("SessionPageResponse").path("properties").has("totalElements")).isTrue();
        assertThat(schemas.path("SankalpaResponse").path("properties").path("endDate")
                .path("type").toString()).contains("null");
        assertThat(schemas.path("LogSessionRequest").path("properties").path("occurredAt")
                .path("description").asText()).contains("application timezone");
        assertThat(schemas.path("DeclareRequest").path("properties").path("timesPerPeriod")
                .path("maximum").asInt()).isEqualTo(99);
        assertThat(schemas.path("DeclareRequest").path("properties").path("periodCount")
                .path("maximum").asInt()).isEqualTo(3650);

        JsonNode outcomeResponses = paths.path("/api/v1/sankalpas/{id}/period-outcomes")
                .path("get").path("responses");
        assertThat(outcomeResponses.has("400")).isTrue();
        assertThat(outcomeResponses.has("422")).isFalse();

        JsonNode pauseResponses = paths.path("/api/v1/sankalpas/{id}/pause").path("post").path("responses");
        assertThat(pauseResponses.has("200")).isTrue();
        assertThat(pauseResponses.has("409")).isTrue();
        assertThat(pauseResponses.has("422")).isTrue();
    }

    @Test
    void sessionIdentityMakesRetryAndDeletionSafe() throws Exception {
        String sankalpaId = declare();
        mvc.perform(post("/api/v1/sankalpas/{id}/begin", sankalpaId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"effectiveAt\":\"2026-06-01T00:00:00\"}"))
                .andExpect(status().isOk());
        String sessionId = "44444444-4444-4444-4444-444444444444";
        String body = "{\"occurredAt\":\"2026-06-01T08:00:00\"}";

        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(sessionId));
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk());
        mvc.perform(delete("/api/v1/sankalpas/{id}/sessions/{sessionId}", sankalpaId, sessionId))
                .andExpect(status().isNoContent());
        mvc.perform(delete("/api/v1/sankalpas/{id}/sessions/{sessionId}", sankalpaId, sessionId))
                .andExpect(status().isNoContent());
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isGone())
                .andExpect(jsonPath("$.code").value("SESSION_DELETED"));
        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", sankalpaId))
                .andExpect(jsonPath("$.totalElements").value(0));
        mvc.perform(get("/api/v1/sankalpas/{id}/period-outcomes", sankalpaId)
                        .queryParam("from", "2026-06-01").queryParam("until", "2026-06-01"))
                .andExpect(jsonPath("$[0].performed").value(0))
                .andExpect(jsonPath("$[0].missed").value(2));
    }

    @Test
    void sessionIdentityRejectsMalformedMismatchedAndChangedCommands() throws Exception {
        String sankalpaId = declare();
        mvc.perform(post("/api/v1/sankalpas/{id}/begin", sankalpaId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"effectiveAt\":\"2026-06-01T00:00:00\"}"))
                .andExpect(status().isOk());
        String sessionId = "66666666-6666-6666-6666-666666666666";
        String otherId = "77777777-7777-7777-7777-777777777777";

        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", "not-a-uuid")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"occurredAt\":\"2026-06-01T08:00:00\"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_REQUEST"));
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"id\":\"" + otherId
                                + "\",\"occurredAt\":\"2026-06-01T08:00:00\"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_REQUEST"));

        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"occurredAt\":\"2026-06-01T08:00:00\"}"))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", sankalpaId)
                        .header("Idempotency-Key", sessionId)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"occurredAt\":\"2026-06-01T09:00:00\"}"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("SESSION_IDENTITY_CONFLICT"));
        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", sankalpaId))
                .andExpect(jsonPath("$.totalElements").value(1));
    }

    @Test
    void deleteBeforeCreateWinsAndIdentityCannotCrossParents() throws Exception {
        String first = declare();
        String second = declare();
        String sessionId = "55555555-5555-5555-5555-555555555555";

        mvc.perform(delete("/api/v1/sankalpas/{id}/sessions/{sessionId}", first, sessionId))
                .andExpect(status().isNoContent());
        mvc.perform(delete("/api/v1/sankalpas/{id}/sessions/{sessionId}", second, sessionId))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("SESSION_IDENTITY_CONFLICT"));
    }

    @Test
    void completeWorkflowMatchesJsonAndHttpContract() throws Exception {
        String id = declare();
        mvc.perform(post("/api/v1/sankalpas/{id}/begin", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"effectiveAt\":\"2026-06-01T00:00:00\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.lifecycleState").value("IN_PROGRESS"));

        log(id, "2026-06-01T08:00:00");
        log(id, "2026-06-01T09:00:00");
        log(id, "2026-06-01T10:00:00");

        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", id)
                        .queryParam("page", "0").queryParam("size", "2"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.content.length()").value(2))
                .andExpect(jsonPath("$.content[0].occurredAt").value("2026-06-01T10:00:00"))
                .andExpect(jsonPath("$.content[1].occurredAt").value("2026-06-01T09:00:00"))
                .andExpect(jsonPath("$.page").value(0))
                .andExpect(jsonPath("$.size").value(2))
                .andExpect(jsonPath("$.totalElements").value(3))
                .andExpect(jsonPath("$.totalPages").value(2));

        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", id)
                        .queryParam("page", "1").queryParam("size", "2"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.content.length()").value(1))
                .andExpect(jsonPath("$.content[0].occurredAt").value("2026-06-01T08:00:00"));

        mvc.perform(get("/api/v1/sankalpas/{id}/period-outcomes", id)
                        .queryParam("from", "2026-06-01").queryParam("until", "2026-06-01"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].required").value(2))
                .andExpect(jsonPath("$[0].performed").value(3))
                .andExpect(jsonPath("$[0].missed").value(0))
                .andExpect(jsonPath("$[0].standing").value("SATISFIED"));

        mvc.perform(get("/api/v1/sankalpas/{id}/lifecycle-history", id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].effectiveAt").value("2026-06-01T00:00:00"))
                .andExpect(jsonPath("$[0].recordedAt").value("2026-06-15T12:00:00"));
    }

    @Test
    void validationAndDomainErrorsUseStableProblemContract() throws Exception {
        mvc.perform(post("/api/v1/sankalpas").contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":" ","actionType":"MEDITATION","startDate":"2026-06-01",
                                 "periodUnit":"DAY","timesPerPeriod":0}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith("application/problem+json"))
                .andExpect(jsonPath("$.code").value("INVALID_REQUEST"))
                .andExpect(jsonPath("$.errors.title").exists())
                .andExpect(jsonPath("$.errors.timesPerPeriod").exists());

        String id = declare();
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"occurredAt\":\"2026-06-02T08:00:00\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("SANKALPA_NOT_IN_PROGRESS"));

        mvc.perform(get("/api/v1/sankalpas/00000000-0000-0000-0000-000000000000"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("SANKALPA_NOT_FOUND"));

        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", id)
                        .queryParam("page", "-1").queryParam("size", "500"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_REQUEST"));

        mvc.perform(get("/api/v1/sankalpas/{id}/sessions", id)
                        .queryParam("from", "2026-06-01"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_DATE_RANGE"));

        mvc.perform(post("/api/v1/sankalpas").contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Too much","actionType":"MEDITATION","startDate":"2026-06-01",
                                 "periodUnit":"DAY","timesPerPeriod":100,"periodCount":3651}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors.timesPerPeriod").exists())
                .andExpect(jsonPath("$.errors.periodCount").exists());

        mvc.perform(post("/api/v1/sankalpas/{id}/begin", id)
                        .contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isOk());
        mvc.perform(post("/api/v1/sankalpas/{id}/pause", id))
                .andExpect(status().isOk());
        mvc.perform(post("/api/v1/sankalpas/{id}/begin", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"effectiveAt\":\"2026-06-01T00:00:00\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value("INVALID_LIFECYCLE_TRANSITION"));

        String indefiniteId = declareIndefinite();
        mvc.perform(get("/api/v1/sankalpas/{id}/period-outcomes", indefiniteId)
                        .queryParam("from", "2026-06-01").queryParam("until", "2036-06-01"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("PERIOD_RANGE_TOO_LARGE"));

        String commandId = "33333333-3333-3333-3333-333333333333";
        mvc.perform(post("/api/v1/sankalpas").contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"id":"%s","title":"First","description":"","actionType":"MEDITATION",
                                 "startDate":"2026-06-01","periodUnit":"DAY","timesPerPeriod":1}
                                """.formatted(commandId)))
                .andExpect(status().isCreated());
        mvc.perform(post("/api/v1/sankalpas").contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"id":"%s","title":"Changed","description":"","actionType":"MEDITATION",
                                 "startDate":"2026-06-01","periodUnit":"DAY","timesPerPeriod":1}
                                """.formatted(commandId)))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value("IDEMPOTENCY_CONFLICT"));
    }

    private String declare() throws Exception {
        String response = mvc.perform(post("/api/v1/sankalpas")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Vipassana","description":"Sit","actionType":"MEDITATION",
                                 "startDate":"2026-06-01","periodUnit":"DAY","timesPerPeriod":2,"periodCount":30}
                                """))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", org.hamcrest.Matchers.containsString("/api/v1/sankalpas/")))
                .andExpect(jsonPath("$.endDate").value("2026-06-30"))
                .andReturn().getResponse().getContentAsString();
        return json.readTree(response).path("id").asText();
    }

    private String declareIndefinite() throws Exception {
        String response = mvc.perform(post("/api/v1/sankalpas")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"title":"Walk","description":"","actionType":"PHYSICAL_ACTIVITY",
                                 "startDate":"2026-06-01","periodUnit":"DAY","timesPerPeriod":1}
                                """))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getContentAsString();
        return json.readTree(response).path("id").asText();
    }

    private void log(String id, String occurredAt) throws Exception {
        mvc.perform(post("/api/v1/sankalpas/{id}/sessions", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"occurredAt\":\"" + occurredAt + "\"}"))
                .andExpect(status().isCreated())
                .andExpect(header().doesNotExist("Location"))
                .andExpect(jsonPath("$.occurredAt").value(occurredAt));
    }

    private boolean hasParameter(JsonNode operation, String name) {
        for (JsonNode parameter : operation.path("parameters")) {
            if (name.equals(parameter.path("name").asText())) return true;
        }
        return false;
    }

    @TestConfiguration
    static class FixedClockConfiguration {
        @Bean @Primary
        SankalpaClock fixedClock() {
            return new SankalpaClock() {
                @Override public LocalDateTime now() { return NOW; }
                @Override public LocalDate today() { return NOW.toLocalDate(); }
            };
        }
    }
}
