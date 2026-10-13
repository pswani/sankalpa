package com.sankalpa.adapter.in.web;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.*;
import static org.assertj.core.api.Assertions.*;

class DeploymentBoundaryTest {
    @Test void productionFailsClosedWithoutCredential() {
        assertThatThrownBy(() -> new DeploymentBoundary("prod", " ").validate()).isInstanceOf(IllegalStateException.class);
        new DeploymentBoundary("local", "").validate();
    }
    @Test void productionRejectsDiagnosticsButAllowsReadiness() throws Exception {
        var boundary=new DeploymentBoundary("prod","token"); boundary.validate();
        var response=new MockHttpServletResponse();
        boundary.doFilter(new MockHttpServletRequest("GET","/v3/api-docs"),response,new MockFilterChain());
        assertThat(response.getStatus()).isEqualTo(404);
        var chain=new MockFilterChain();
        boundary.doFilter(new MockHttpServletRequest("GET","/health/ready"),new MockHttpServletResponse(),chain);
        assertThat(chain.getRequest()).isNotNull();
    }
}
