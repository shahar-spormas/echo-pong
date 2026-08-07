FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

WORKDIR /src

COPY go.mod ./
# Optional: --mount=type=cache,target=/go/pkg/mod to reuse module downloads across builds.
# It might cause issues with not taking the latest version of the packages and wont be as secure.
RUN go mod download

COPY . .

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags='-s -w' -o /out/ping-pong-app .

# Actually image    
FROM gcr.io/distroless/static-debian12:nonroot

# optional labels, could be used for monitoring, logging, etc.
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="ping-pong-game" \
      org.opencontainers.image.description="Ping-pong HTTP server and CLI" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$REVISION" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian12:nonroot"

COPY --from=builder /out/ping-pong-app /usr/local/bin/ping-pong-app

ENV SECRET_FILE_PATH=/etc/ping-pong/secret \
    PORT=8080

EXPOSE 8080

# nonroot user from the image
USER 65532:65532 

ENTRYPOINT ["/usr/local/bin/ping-pong-app"]
CMD ["--mode=server"]
