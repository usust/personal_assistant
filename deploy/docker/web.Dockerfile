FROM node:22-alpine AS build
WORKDIR /source
COPY apps/web/package*.json ./apps/web/
RUN cd apps/web && npm ci
COPY apps/web ./apps/web
COPY shared ./shared
COPY scripts ./scripts
ENV VITE_API_BASE_URL=/api
RUN cd apps/web && npm test && npm run build

FROM nginx:stable-alpine
COPY deploy/docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /source/apps/web/dist /usr/share/nginx/html
EXPOSE 80
