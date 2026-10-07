package com.sankalpa.adapter;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@ExtendWith(OutputCaptureExtension.class)
class RequestLoggingTest {
    @Autowired MockMvc mvc;
    @Autowired ObjectMapper json;

    @Test
    void changesAndRefusalsAreLoggedWithoutTheUsersText(CapturedOutput output) throws Exception {
        String body = """
                {"title":"Private intention","description":"Private note","actionType":"MEDITATION",
                 "startDate":"%s","periodUnit":"DAY","timesPerPeriod":1,"periodCount":null}
                """.formatted(LocalDate.now());
        String created = mvc.perform(post("/api/v1/sankalpas")
                        .contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        String id = json.readTree(created).path("id").asText();

        mvc.perform(post("/api/v1/sankalpas/" + id + "/pause")).andExpect(status().isUnprocessableEntity());
        mvc.perform(get("/api/v1/sankalpas")).andExpect(status().isOk());

        assertThat(output).contains("POST /api/v1/sankalpas -> 201");
        assertThat(output).contains("POST /api/v1/sankalpas/" + id + "/pause -> 422 INVALID_LIFECYCLE_TRANSITION");
        // Routine reads are DEBUG, so a refreshing phone does not flood the log.
        assertThat(output).doesNotContain("GET /api/v1/sankalpas -> 200");
        assertThat(output).doesNotContain("Private intention").doesNotContain("Private note");
    }
}
