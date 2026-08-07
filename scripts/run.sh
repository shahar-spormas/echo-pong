#!/usr/bin/env bash
# For testing — runs the container locally with the secret mounted.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-ping-pong-game}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
CONTAINER_NAME="${CONTAINER_NAME:-ping-pong-dev}"
HOST_PORT="${HOST_PORT:-18080}" # my 8080 port is already taken
SECRET_FILE="${SECRET_FILE:-$ROOT_DIR/secrets/token}"

IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

cd "$ROOT_DIR"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image $IMAGE not found. Run scripts/build.sh first." >&2
  exit 1
fi

# generate a secret file, because secrets dir is exculded from git
if [[ ! -f "$SECRET_FILE" ]]; then
  mkdir -p "$(dirname "$SECRET_FILE")"
  openssl rand -hex 16 > "$SECRET_FILE"
  echo "Generated a test secret at $SECRET_FILE"
fi

# 644 (read only for others)
chmod o+r "$SECRET_FILE"

# remove the contianer if its exists
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d \
  --name "$CONTAINER_NAME" \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -v "${SECRET_FILE}:/etc/ping-pong/secret:ro" \
  "$IMAGE" >/dev/null

echo "Started $CONTAINER_NAME from $IMAGE on port $HOST_PORT"
echo -n "Waiting for /health (the server sleeps 10s before listening)"

# check health
for _ in $(seq 1 40); do
  if [[ "$(curl -fsS -o /dev/null -w '%{http_code}' "http://localhost:${HOST_PORT}/health" 2>/dev/null || true)" == "200" ]]; then
    READY=1
    break
  fi
  echo -n "."
  sleep 1
done
echo

if [[ "${READY:-}" != "1" ]]; then
  echo "Never became healthy. Logs:" >&2
  docker logs "$CONTAINER_NAME" >&2
  exit 1
fi

TOKEN="$(cat "$SECRET_FILE")"

cat <<EOF
Ready.

  curl http://localhost:${HOST_PORT}/health
  curl -H "Authorization: Bearer ${TOKEN}" http://localhost:${HOST_PORT}/ping
  curl -H "Authorization: Bearer ${TOKEN}" http://localhost:${HOST_PORT}/pong

CLI mode:

  docker run --rm -v "${SECRET_FILE}:/etc/ping-pong/secret:ro" ${IMAGE} \\
    --mode=cli --password="${TOKEN}" ping

Logs:  docker logs -f ${CONTAINER_NAME}
Stop:  docker rm -f ${CONTAINER_NAME}
EOF
