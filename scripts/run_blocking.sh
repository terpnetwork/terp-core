#!/bin/bash

set -e

GIT_TAG=$(git describe --tags)

echo "> Running $GIT_TAG..."

docker run --rm -it -p 26657:26657 --name terp-local terpnetwork/terp-core:$GIT_TAG /bin/sh -c "./setup_and_run.sh"