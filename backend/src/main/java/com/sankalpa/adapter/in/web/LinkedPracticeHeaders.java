package com.sankalpa.adapter.in.web;

import java.lang.annotation.*;

/** Shared OpenAPI description for explicit linked-practice negotiation. */
@Retention(RetentionPolicy.RUNTIME)
@Target({ElementType.METHOD, ElementType.ANNOTATION_TYPE})
@io.swagger.v3.oas.annotations.Parameters({
        @io.swagger.v3.oas.annotations.Parameter(name="Linked-Sankalpa-Version", in=io.swagger.v3.oas.annotations.enums.ParameterIn.HEADER,
                description="Send 1 to negotiate linked contributions; required for linked requests"),
        @io.swagger.v3.oas.annotations.Parameter(name="Sankalpa-Service-Instance", in=io.swagger.v3.oas.annotations.enums.ParameterIn.HEADER,
                description="Verified service instance UUID; required with linked contract 1"),
        @io.swagger.v3.oas.annotations.Parameter(name="Sankalpa-Practice-Revision", in=io.swagger.v3.oas.annotations.enums.ParameterIn.HEADER,
                description="Nonnegative decimal string from the first read; pins subsequent refresh reads")
})
public @interface LinkedPracticeHeaders {}
