package com.sankalpa.adapter.in.web;

import com.sankalpa.adapter.out.persistence.ServiceInstanceIdentity;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.ResponseEntity;

@RestController
public final class ReadinessController {
    private final ServiceInstanceIdentity identity;
    public ReadinessController(ServiceInstanceIdentity identity) { this.identity = identity; }
    @GetMapping("/health/ready") public ResponseEntity<Void> ready() {
        return identity.value() == null ? ResponseEntity.status(503).build() : ResponseEntity.ok().build();
    }
}
