#!/usr/bin/env bash
# For testing — builds the container image locally.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-ping-pong-game}"
IMAGE_TAG="${IMAGE_TAG:-dev}"

cd "$ROOT_DIR"

docker build \
  --build-arg VERSION="$IMAGE_TAG" \
  --build-arg REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  .

echo "Built ${IMAGE_NAME}:${IMAGE_TAG}"
