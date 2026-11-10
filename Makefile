# Convenience targets. Everything runs in containers, so the only local
# requirement is Docker (plus kind/kubectl/helm for `make k8s`).
SHELL := /bin/bash
.DEFAULT_GOAL := help

GO_IMAGE        := golang:1.27.3-alpine3.24
GOLANGCI_IMAGE  := golangci/golangci-lint:v2.15.0-alpine
SHELLCHECK      := koalaman/shellcheck:v0.11.0
HADOLINT        := hadolint/hadolint:v2.15.1
TRIVY           := aquasec/trivy:0.76.2
PROMETHEUS      := prom/prometheus:v3.16.0
VERSION         ?= 0.1.0-local

GO_RUN = docker run --rm -v "$(CURDIR)/app:/src" -w /src -v go-mod-cache:/go/pkg/mod -v go-build-cache:/root/.cache/go-build

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: test
test: ## Run Go unit tests with race detector and coverage
	$(GO_RUN) $(GO_IMAGE) sh -c 'apk add -q --no-cache gcc musl-dev >/dev/null && CGO_ENABLED=1 go test -race -cover ./...'

.PHONY: lint
lint: ## golangci-lint, hadolint, shellcheck, promtool rule tests
	$(GO_RUN) $(GOLANGCI_IMAGE) golangci-lint run ./...
	docker run --rm -i $(HADOLINT) < Dockerfile
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK) --severity=style scripts/*.sh
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/p:ro" -w /p/tests --entrypoint promtool $(PROMETHEUS) test rules alerts_test.yml

.PHONY: build
build: ## Build the container image (hello-devops:local)
	docker build -t hello-devops:local --build-arg VERSION=$(VERSION) \
	  --build-arg REVISION=$$(git rev-parse --short HEAD) --build-arg CREATED=$$(date -u +%Y-%m-%dT%H:%M:%SZ) .
	@docker image ls hello-devops:local

.PHONY: scan
scan: build ## Trivy scan of the local image (fails on CRITICAL)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock $(TRIVY) image --severity CRITICAL --exit-code 1 hello-devops:local

.env:
	cp .env.example .env
	@sed -i.bak "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$$(openssl rand -hex 12)/" .env && rm -f .env.bak
	@echo "Created .env with a random Grafana password: grep GRAFANA_ADMIN_PASSWORD .env"

.PHONY: up
up: .env ## Start app + observability stack (docker compose)
	docker compose up -d --build
	@echo "App:     http://localhost:8080"
	@echo "Grafana: http://localhost:3000  (user/pass in .env)"

.PHONY: down
down: ## Stop the stack (keeps volumes)
	docker compose down

.PHONY: health
health: ## Run the health script once (text output)
	scripts/system_health.sh --log-file ./health_log.txt || true

.PHONY: k8s
k8s: ## Create the kind cluster and deploy (needs kind, kubectl, helm)
	scripts/k8s-up.sh

.PHONY: k8s-down
k8s-down: ## Delete the kind cluster
	kind delete cluster --name hello-devops
