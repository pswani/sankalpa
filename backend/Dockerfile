FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml ./
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn --batch-mode -DskipTests package

FROM eclipse-temurin:21-jre-jammy
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter
WORKDIR /app
COPY --from=build /build/target/sankalpa-backend-*.jar /app/backend.jar
ENV PORT=8080 AWS_LWA_PORT=8080 AWS_LWA_READINESS_CHECK_PATH=/health/ready AWS_LWA_READINESS_CHECK_HEALTHY_STATUS=200 AWS_LWA_ASYNC_INIT=true AWS_LWA_INVOKE_MODE=response_stream
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=45s CMD curl --fail --silent http://localhost:8080/health/ready || exit 1
ENTRYPOINT ["java", "-Djava.io.tmpdir=/tmp", "-jar", "/app/backend.jar"]
