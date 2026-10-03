.PHONY: dev-backend dev-frontend test build

dev-backend:
	cd backend && go run .

dev-frontend:
	cd apps/web && npm run dev

test:
	cd backend && go test ./...
	cd backend && go vet ./...
	cd apps/web && npm run type-check
	cd apps/web && npm test

build:
	cd backend && go build ./...
	cd apps/web && npm run build
