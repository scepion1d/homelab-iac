# Built locally by docker compose. No pre-built image of the
# letsencrypt/unbound_exporter Go binary is currently published to a
# public registry (kumina's docker hub image was removed mid-2025).
# Building from source is fast (~30s) and self-contained.

FROM golang:1.26-alpine AS builder
RUN apk add --no-cache git
ARG EXPORTER_VERSION=v0.6.0
RUN go install github.com/letsencrypt/unbound_exporter@${EXPORTER_VERSION}

FROM alpine:3.21
COPY --from=builder /go/bin/unbound_exporter /usr/bin/unbound_exporter
ENTRYPOINT ["/usr/bin/unbound_exporter"]
