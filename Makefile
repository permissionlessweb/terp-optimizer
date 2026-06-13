# Docker names
DN_OPTIMIZER := terpnetwork/optimizer
DN_RUST_OPTIMIZER := terpnetwork/rust-optimizer
DN_WORKSPACE_OPTIMIZER := terpnetwork/workspace-optimizer
DOCKER_TAG := 0.17.0

# Native arch detection
BUILDARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

.PHONY: build
build: build-$(BUILDARCH)

.PHONY: build-amd64
build-amd64:
	docker buildx build --pull --platform linux/amd64 \
		-t $(DN_OPTIMIZER):$(DOCKER_TAG) \
		-t $(DN_RUST_OPTIMIZER):$(DOCKER_TAG) \
		-t $(DN_WORKSPACE_OPTIMIZER):$(DOCKER_TAG) \
		--load .

.PHONY: build-arm64
build-arm64:
	docker buildx build --pull --platform linux/arm64/v8 \
		-t $(DN_OPTIMIZER)-arm64:$(DOCKER_TAG) \
		-t $(DN_RUST_OPTIMIZER)-arm64:$(DOCKER_TAG) \
		-t $(DN_WORKSPACE_OPTIMIZER)-arm64:$(DOCKER_TAG) \
		--load .

.PHONY: publish-amd64
publish-amd64: build-amd64
	docker push $(DN_OPTIMIZER):$(DOCKER_TAG)
	docker push $(DN_RUST_OPTIMIZER):$(DOCKER_TAG)
	docker push $(DN_WORKSPACE_OPTIMIZER):$(DOCKER_TAG)

.PHONY: publish-arm64
publish-arm64: build-arm64
	docker push $(DN_OPTIMIZER)-arm64:$(DOCKER_TAG)
	docker push $(DN_RUST_OPTIMIZER)-arm64:$(DOCKER_TAG)
	docker push $(DN_WORKSPACE_OPTIMIZER)-arm64:$(DOCKER_TAG)

# Optional: build both architectures (useful for CI)
.PHONY: build-all
build-all: build-amd64 build-arm64