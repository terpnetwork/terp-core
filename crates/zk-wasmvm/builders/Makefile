# 4.0.0-zk uses OUR images only.
# Do not pull or push cosmwasm/libwasmvm-builder:0103-* (rustc 1.86, no Path A).
# See docs/BUILDERS.md and builders/README.md.
ZK_TAG := 4.0.0-zk

.PHONY: docker-image-alpine-nightly
docker-image-alpine-nightly:
	docker build --platform linux/amd64 . -t terpnetwork/zk-alpine-builder:$(ZK_TAG) -f ./Dockerfile.alpine-nightly

.PHONY: docker-image-debian-nightly
docker-image-debian-nightly:
	docker build --platform linux/amd64 . -t terpnetwork/zk-debian-builder:$(ZK_TAG) -f ./Dockerfile.debian-nightly

.PHONY: docker-image-cross-nightly
docker-image-cross-nightly:
	docker build --platform linux/amd64 . -t terpnetwork/zk-cross-builder:$(ZK_TAG) -f ./Dockerfile.cross-nightly

.PHONY: docker-images-4.0.0-zk
docker-images-4.0.0-zk: docker-image-alpine-nightly docker-image-debian-nightly docker-image-cross-nightly

# Builders are local compile images (2–8GB). Do not push them to
# registry.terp.network (413 on 5GB layers) or GHCR. Release artifacts are
# linux terpd + muslc on S3; runtime image is registry.terp.network/terp-core:<tag>.
.PHONY: docker-publish-4.0.0-zk
docker-publish-4.0.0-zk:
	@echo "ERROR: do not push zk-*-builder images." >&2
	@echo "Builders stay local: terpnetwork/zk-*-builder:$(ZK_TAG)" >&2
	@echo "Compiled release: S3 releases/zk-wasmvm/v4.0.0-zk/ and registry.terp.network/terp-core:<tag>" >&2
	@echo "See networks/upgrades/v6.3/REGISTRY-HANDOFF.md" >&2
	@exit 1

# Default `docker-images` used to build CosmWasm 0103. That is the mixed-generation trip.
.PHONY: docker-images
docker-images:
	@echo "ERROR: 4.0.0-zk does not use cosmwasm/libwasmvm-builder:0103-*." >&2
	@echo "Build ours:  make docker-images-4.0.0-zk" >&2
	@echo "Builders stay local (do not push). Release image: registry.terp.network/terp-core:<tag>" >&2
	@echo "Upstream 0103 (do not use for Path A): make docker-images-upstream-0103" >&2
	@exit 1

.PHONY: docker-publish
docker-publish: docker-images

# Historical CosmWasm 0103 (rustc 1.86). Not Path A. Not 4.0.0-zk.
BUILDERS_PREFIX := cosmwasm/libwasmvm-builder:0103

.PHONY: docker-image-debian
docker-image-debian:
	docker build --pull . -t $(BUILDERS_PREFIX)-debian -f ./Dockerfile.debian

.PHONY: docker-image-cross
docker-image-cross:
	docker build --pull . -t $(BUILDERS_PREFIX)-cross -f ./Dockerfile.cross

.PHONY: docker-image-alpine
docker-image-alpine:
	docker build --pull . -t $(BUILDERS_PREFIX)-alpine -f ./Dockerfile.alpine

.PHONY: docker-images-upstream-0103
docker-images-upstream-0103: docker-image-debian docker-image-cross docker-image-alpine
