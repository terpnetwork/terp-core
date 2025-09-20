#!/bin/bash

set -e  # Exit on any error

# Set environment variables
export GOLANG_PROTOBUF_VERSION=1.36.6
export GRPC_GATEWAY_VERSION=1.16.0

echo "🔧 Installing protobuf tools..."

# Install required Go tools
go install github.com/cosmos/cosmos-proto/cmd/protoc-gen-go-pulsar@latest
go install google.golang.org/protobuf/cmd/protoc-gen-go@v${GOLANG_PROTOBUF_VERSION}
go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway@v${GRPC_GATEWAY_VERSION}
go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-swagger@v${GRPC_GATEWAY_VERSION}

echo "📦 Installing gogoproto..."

# Clone and install gogoproto
if [ -d "gogoproto" ]; then
    echo "Removing existing gogoproto directory..."
    rm -rf gogoproto
fi

git clone https://github.com/cosmos/gogoproto.git
cd gogoproto
go mod download
make install
cd ..

echo "🏗️  Generating protobuf files..."

# Generate protobuf files
cd proto
buf dep update
cd ..
buf generate

echo "📁 Moving generated files to correct locations..."

# Move generated proto files to the right places
cp -r ./github.com/terpnetwork/terp-core/x/* x/
cp -r ./github.com/cosmos/gaia/x/* x/
# Uncomment and modify the line below for additional proto imports:
# cp -r ./github.com/<any-other>/<proto-imports>/x/* x/

echo "🧹 Cleaning up temporary files..."

# Clean up
rm -rf ./github.com
rm -rf gogoproto

echo "✅ Proto generation complete!"