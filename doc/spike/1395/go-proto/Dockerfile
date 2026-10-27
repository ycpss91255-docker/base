# setupgen prototype image (base#1395): pinned Go builder -> scratch.
ARG GO_IMAGE=golang:1.27.2-alpine3.24
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
# No defaults: a default here shadows the value BuildKit derives from
# --platform, and a linux/arm64 build silently ships an amd64 binary.
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w" -o /out/setupgen .

FROM scratch
COPY --from=build /out/setupgen /setupgen
USER 65534:65534
ENTRYPOINT ["/setupgen"]
