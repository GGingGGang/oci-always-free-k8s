FROM docker.io/golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETARCH
ARG GIT_SHA=unknown
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${GIT_SHA}" \
      -o /out/__SVC__ \
      ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/__SVC__ /__SVC__
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/__SVC__"]
