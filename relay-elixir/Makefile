PROJECT_ID ?= zaf-sandbox
IMAGE_NAME  ?= a2a-relay-elixir
SERVICE_NAME ?= a2a-relay-elixir-dev
REGION      ?= us-central1
COMMIT_SHA  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")

.PHONY: help build push deploy ship-dev test

help:
	@echo "Targets:"
	@echo "  make build      — build Docker image locally"
	@echo "  make push       — push image to GCR"
	@echo "  make deploy     — deploy to Cloud Run (dev)"
	@echo "  make ship-dev   — build + push + deploy"
	@echo "  make test       — run mix test"

test:
	mix test

build:
	docker build \
		-t gcr.io/$(PROJECT_ID)/$(IMAGE_NAME):latest \
		-t gcr.io/$(PROJECT_ID)/$(IMAGE_NAME):$(COMMIT_SHA) \
		.

push: build
	docker push --all-tags gcr.io/$(PROJECT_ID)/$(IMAGE_NAME)

deploy:
	gcloud run deploy $(SERVICE_NAME) \
		--image=gcr.io/$(PROJECT_ID)/$(IMAGE_NAME):$(COMMIT_SHA) \
		--region=$(REGION) \
		--platform=managed \
		--allow-unauthenticated \
		--port=8080 \
		--memory=512Mi \
		--cpu=1 \
		--project=$(PROJECT_ID)

ship-dev: build push deploy
