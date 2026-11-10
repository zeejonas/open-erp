# syntax=docker/dockerfile:1
FROM swift:6.3-noble AS build
WORKDIR /build
COPY Package.* ./
RUN swift package resolve
COPY Sources ./Sources
RUN --mount=type=cache,id=loadtest-oidc-stub,target=/build/.build \
    swift build -c release --static-swift-stdlib && \
    cp "$(swift build -c release --show-bin-path)/OIDCStub" /OIDCStub

FROM ubuntu:noble
COPY --from=build /OIDCStub /OIDCStub
USER nobody
ENTRYPOINT ["/OIDCStub"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8081"]
