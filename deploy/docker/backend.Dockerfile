FROM golang:1.26-alpine AS build
WORKDIR /source/backend
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/backend .

FROM alpine:3.24
RUN apk add --no-cache ca-certificates tzdata wget && addgroup -g 10001 app && adduser -D -u 10001 -G app app
WORKDIR /app
COPY --from=build /out/backend /app/backend
USER 10001:10001
ENV PA_CONFIG_FILE=/app/config.yaml TZ=Asia/Singapore
EXPOSE 20000
ENTRYPOINT ["/app/backend"]
