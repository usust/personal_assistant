FROM alpine:3.24
RUN apk add --no-cache ca-certificates tzdata wget && addgroup -g 10001 app && adduser -D -u 10001 -G app app
WORKDIR /app
COPY backend /app/backend
RUN chmod 755 /app/backend
USER 10001:10001
ENV PA_CONFIG_FILE=/app/config.yaml TZ=Asia/Singapore
EXPOSE 20000
ENTRYPOINT ["/app/backend"]
