###############################################################################
###                                  Proto                                  ###
###############################################################################

proto-help:
	@echo "proto subcommands"
	@echo ""
	@echo "Usage:"
	@echo "  make proto-[command]"
	@echo ""
	@echo "Available Commands:"
	@echo "  all        Run proto-format and proto-gen for swagger & pulsar"
	@echo "  format     Format Protobuf files"
	@echo "  gen-swagger        Generate Swagger Protobuf files"
	@echo "  gen-pulsar         Generate Pulsar Protobuf files"
	@echo "  image-build  Build the protobuf Docker image"
	@echo "  image-push  Push the protobuf Docker image"

proto: proto-help

# export DOCKER_BUILDKIT=1
# export DOCKER_DEFAULT_PLATFORM=linux/amd64

protoVer=0.15.1
protoImageName=ghcr.io/cosmos/proto-builder:$(protoVer)
protoImage=$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(protoImageName)
SWAGGER_DIR=./swagger-proto


proto-all: proto-format proto-gen-pulsar proto-gen-swagger

proto-gen-pulsar:
	@$(protoImage) sh ./scripts/get-pulsar.sh

proto-gen-swagger:
	@$(protoImage) sh ./scripts/gen-swagger.sh

proto-lint:
	@$(protoImage) buf lint --error-format=json

proto-format:
	@echo "Formatting Protobuf files"
	@$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace tendermintdev/docker-build-proto \
		find ./proto -name "*.proto" -exec clang-format -i {} \;

proto-check-breaking:
	@$(CURDIR) $(protoImage) buf breaking --against $(HTTPS_GIT)#branch=main

SWAGGER_DIR=./swagger-proto
THIRD_PARTY_DIR=$(SWAGGER_DIR)/third_party

proto-download-deps:
	mkdir -p "$(THIRD_PARTY_DIR)/cosmos_tmp" && \
	cd "$(THIRD_PARTY_DIR)/cosmos_tmp" && \
	git init && \
	git remote add origin "https://github.com/cosmos/cosmos-sdk.git" && \
	git config core.sparseCheckout true && \
	printf "proto\nthird_party\n" > .git/info/sparse-checkout && \
	git pull origin main && \
	rm -f ./proto/buf.* && \
	mv ./proto/* ..
	rm -rf "$(THIRD_PARTY_DIR)/cosmos_tmp"

	mkdir -p "$(THIRD_PARTY_DIR)/ibc_tmp" && \
	cd "$(THIRD_PARTY_DIR)/ibc_tmp" && \
	git init && \
	git remote add origin "https://github.com/cosmos/ibc-go.git" && \
	git config core.sparseCheckout true && \
	printf "proto\n" > .git/info/sparse-checkout && \
	git pull origin main && \
	rm -f ./proto/buf.* && \
	mv ./proto/* ..
	rm -rf "$(THIRD_PARTY_DIR)/ibc_tmp"

	mkdir -p "$(THIRD_PARTY_DIR)/cosmos_proto_tmp" && \
	cd "$(THIRD_PARTY_DIR)/cosmos_proto_tmp" && \
	git init && \
	git remote add origin "https://github.com/cosmos/cosmos-proto.git" && \
	git config core.sparseCheckout true && \
	printf "proto\n" > .git/info/sparse-checkout && \
	git pull origin main && \
	rm -f ./proto/buf.* && \
	mv ./proto/* ..
	rm -rf "$(THIRD_PARTY_DIR)/cosmos_proto_tmp"

	mkdir -p "$(THIRD_PARTY_DIR)/gogoproto" && \
	curl -SSL https://raw.githubusercontent.com/cosmos/gogoproto/main/gogoproto/gogo.proto > "$(THIRD_PARTY_DIR)/gogoproto/gogo.proto"

	mkdir -p "$(THIRD_PARTY_DIR)/google/api" && \
	curl -sSL https://raw.githubusercontent.com/googleapis/googleapis/master/google/api/annotations.proto > "$(THIRD_PARTY_DIR)/google/api/annotations.proto"
	curl -sSL https://raw.githubusercontent.com/googleapis/googleapis/master/google/api/http.proto > "$(THIRD_PARTY_DIR)/google/api/http.proto"

	mkdir -p "$(THIRD_PARTY_DIR)/cosmos/ics23/v1" && \
	curl -sSL https://raw.githubusercontent.com/cosmos/ics23/master/proto/cosmos/ics23/v1/proofs.proto > "$(THIRD_PARTY_DIR)/cosmos/ics23/v1/proofs.proto"
