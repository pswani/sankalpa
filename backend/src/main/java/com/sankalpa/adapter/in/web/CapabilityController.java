package com.sankalpa.adapter.in.web;

import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.beans.factory.annotation.Value;

import static com.sankalpa.adapter.in.web.ApiModels.CapabilitiesResponse;

@RestController
@RequestMapping(value = "/api/v1/capabilities", produces = MediaType.APPLICATION_JSON_VALUE)
public final class CapabilityController {
    private final ServiceInstanceIdentity identity;
    private final boolean assistantEnabled;
    private final boolean authenticationRequired;

    public CapabilityController(ServiceInstanceIdentity identity,
            @Value("${sankalpa.assistant.enabled:false}") boolean assistantEnabled,
            @Value("${sankalpa.assistant.api-token:}") String apiToken) {
        this.identity = identity;
        this.assistantEnabled = assistantEnabled;
        this.authenticationRequired = !apiToken.isBlank();
    }

    @GetMapping
    @Operation(summary = "Advertise cross-version command capabilities")
    @ApiResponse(responseCode = "200", description = "Capabilities and persistent service identity returned")
    public CapabilitiesResponse capabilities() {
        return new CapabilitiesResponse(1, identity.value(), new ApiModels.AssistantCapability(
                assistantEnabled, "ag-ui-sankalpa/1", 20, 65_536, 262_144,
                authenticationRequired));
    }
}
