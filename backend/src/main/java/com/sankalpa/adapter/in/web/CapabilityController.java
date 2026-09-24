package com.sankalpa.adapter.in.web;

import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import static com.sankalpa.adapter.in.web.ApiModels.CapabilitiesResponse;

@RestController
@RequestMapping(value = "/api/v1/capabilities", produces = MediaType.APPLICATION_JSON_VALUE)
public final class CapabilityController {
    private final ServiceInstanceIdentity identity;

    public CapabilityController(ServiceInstanceIdentity identity) { this.identity = identity; }

    @GetMapping
    @Operation(summary = "Advertise cross-version command capabilities")
    @ApiResponse(responseCode = "200", description = "Capabilities and persistent service identity returned")
    public CapabilitiesResponse capabilities() {
        return new CapabilitiesResponse(1, identity.value());
    }
}
