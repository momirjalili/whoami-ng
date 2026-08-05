# syntax=docker/dockerfile:1

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY internal ./internal
COPY web ./web
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=${VERSION}" -o /out/whoami-ng .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/whoami-ng /whoami-ng
# Numeric UID/GID (not the "nonroot" name) so kubelet's runAsNonRoot check
# can verify non-root without a matching /etc/passwd entry in the image.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/whoami-ng"]
