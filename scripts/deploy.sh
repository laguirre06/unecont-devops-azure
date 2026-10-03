#!/usr/bin/env bash
set -euo pipefail

# Explicit context prevents accidental changes in another cluster.
readonly CONTEXT="kind-unecont"
readonly NAMESPACE="unecont"
readonly DEPLOYMENT="api"
readonly CONTAINER="api"

NEW_IMAGE="${1:-}"
TIMEOUT="${2:-90}"

if [[ -z "$NEW_IMAGE" || ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: bash scripts/deploy.sh GHCR_IMAGE [TIMEOUT_SECONDS]" >&2
  exit 2
fi

# Restrict this demo to the application registry and valid reference characters.
if [[ ! "$NEW_IMAGE" =~ ^ghcr\.io/laguirre06/unecont-devops-azure(:[A-Za-z0-9_.-]+|@sha256:[a-f0-9]{64})$ ]]; then
  echo "Unsupported image reference: $NEW_IMAGE" >&2
  exit 2
fi

command -v kubectl >/dev/null

K=(kubectl --context "$CONTEXT" -n "$NAMESPACE")

if [[ "$("${K[@]}" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.spec.paused}')" == "true" ]]; then
  echo "Deployment is paused; investigate before deploying." >&2
  exit 2
fi

# Only deploy from a healthy baseline so rollback has a known good target.
"${K[@]}" rollout status "deployment/$DEPLOYMENT" --timeout=30s

OLD_IMAGE="$("${K[@]}" get deployment "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')"

OLD_REVISION="$("${K[@]}" get deployment "$DEPLOYMENT" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')"

if [[ -z "$OLD_IMAGE" || ! "$OLD_REVISION" =~ ^[0-9]+$ ]]; then
  echo "Cannot determine previous image/revision." >&2
  exit 2
fi

if [[ "$NEW_IMAGE" == "$OLD_IMAGE" ]]; then
  echo "Requested image is already deployed and rollout is healthy."
  exit 0
fi

echo "Context=$CONTEXT Namespace=$NAMESPACE Deployment=$DEPLOYMENT"
echo "PreviousRevision=$OLD_REVISION"
echo "PreviousImage=$OLD_IMAGE"
echo "RequestedImage=$NEW_IMAGE"

rollback() {
  trap - INT TERM

  local current_image
  current_image="$("${K[@]}" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')" || return 1

  # Avoid overwriting another deployment that changed the requested image.
  if [[ "$current_image" != "$NEW_IMAGE" ]]; then
    echo "Image changed externally; automatic rollback aborted." >&2
    return 1
  fi

  echo "Restoring previous revision $OLD_REVISION..."
  "${K[@]}" rollout undo "deployment/$DEPLOYMENT" \
    --to-revision="$OLD_REVISION" || return 1

  "${K[@]}" rollout status "deployment/$DEPLOYMENT" \
    --timeout="${TIMEOUT}s" || return 1

  local restored_image
  restored_image="$("${K[@]}" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}')" || return 1

  [[ "$restored_image" == "$OLD_IMAGE" ]] || return 1
  echo "Rollback completed; previous image restored."
}

if ! "${K[@]}" set image "deployment/$DEPLOYMENT" "$CONTAINER=$NEW_IMAGE"; then
  echo "Image update failed; inspect the deployment before retrying." >&2
  exit 1
fi

# Recover on an interactive interruption after the image update.
trap 'rollback || true; exit 130' INT
trap 'rollback || true; exit 143' TERM

if "${K[@]}" rollout status "deployment/$DEPLOYMENT" --timeout="${TIMEOUT}s"; then
  trap - INT TERM
  echo "Deploy completed successfully."
  "${K[@]}" get pods -l app=api
  exit 0
fi

echo "Rollout failed; collecting diagnostics..." >&2
"${K[@]}" get pods -l app=api -o wide || true
"${K[@]}" describe deployment "$DEPLOYMENT" || true
"${K[@]}" get events --sort-by=.metadata.creationTimestamp | tail -n 20 || true

# Restore the complete pod template, rather than changing only its image.
# Database migrations are outside this rollback's scope.
if rollback; then
  exit 1
else
  echo "Rollback failed or was aborted; manual investigation required." >&2
  exit 3
fi
