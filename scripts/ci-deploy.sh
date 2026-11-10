#!/usr/bin/env bash
#
# ci-deploy.sh — deploy an image tag to an EC2 instance via SSM Run Command,
# smoke-test it from outside, and roll back automatically if it fails.
#
# Two layers of protection:
#   1. On the instance, `hello-devops-deploy <tag>` health-checks the new
#      container on localhost and restores the previous container itself if
#      it never becomes healthy (SSM command then reports Failed).
#   2. From the CI runner, this script checks the public /health endpoint and
#      that / reports the expected version. If that fails (e.g. healthy on
#      localhost but unreachable), it runs `hello-devops-deploy --rollback`.
#
# Usage:
#   ci-deploy.sh --instance-id i-0123 --tag 0.1.42 --url http://host [--region ap-southeast-1]
#
# Requires: aws (v2), curl, jq. AWS credentials come from GitHub OIDC.

set -euo pipefail

REGION=${AWS_REGION:-}
INSTANCE_ID=""
TAG=""
URL=""
SSM_TIMEOUT=600          # seconds SSM allows the remote command to run
POLL_TIMEOUT=420         # seconds we wait for the command result
SMOKE_ATTEMPTS=12        # × 5s = 1 minute

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "::error::$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --instance-id) INSTANCE_ID=${2:-}; shift 2 ;;
    --tag)         TAG=${2:-}; shift 2 ;;
    --url)         URL=${2%/}; shift 2 ;;
    --region)      REGION=${2:-}; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$INSTANCE_ID" && -n "$TAG" && -n "$URL" && -n "$REGION" ]] \
  || { usage >&2; die "--instance-id, --tag, --url and --region (or AWS_REGION) are required"; }
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid tag: $TAG"
for cmd in aws curl jq; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done

# run_remote <command> — run a shell command on the instance, stream result.
# Returns 0 if the SSM invocation succeeded.
run_remote() {
  local cmd=$1 id status deadline
  id=$(aws ssm send-command \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --comment "hello-devops ${GITHUB_RUN_ID:-manual}: ${cmd:0:60}" \
        --timeout-seconds "$SSM_TIMEOUT" \
        --parameters "$(jq -cn --arg c "$cmd" '{commands: [$c]}')" \
        --query Command.CommandId --output text)
  echo "SSM command id: $id"

  deadline=$((SECONDS + POLL_TIMEOUT))
  status=Pending
  while ((SECONDS < deadline)); do
    sleep 5
    status=$(aws ssm get-command-invocation --region "$REGION" \
               --command-id "$id" --instance-id "$INSTANCE_ID" \
               --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Pending|InProgress|Delayed) continue ;;
      *) break ;;
    esac
  done

  aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE_ID" \
    --query '{stdout: StandardOutputContent, stderr: StandardErrorContent}' --output json \
    | jq -r '"--- remote stdout ---\n" + .stdout + (if .stderr != "" then "--- remote stderr ---\n" + .stderr else "" end)'
  echo "SSM status: $status"
  [[ "$status" == "Success" ]]
}

smoke_test() {
  local i body
  for ((i = 1; i <= SMOKE_ATTEMPTS; i++)); do
    if curl -fsS -m 5 "$URL/health" >/dev/null 2>&1 \
       && body=$(curl -fsS -m 5 "$URL/") \
       && jq -e --arg v "$TAG" '.status == "running" and .version == $v' <<<"$body" >/dev/null; then
      echo "smoke test passed (attempt $i): $body"
      return 0
    fi
    echo "smoke test attempt $i/$SMOKE_ATTEMPTS failed; retrying in 5s"
    sleep 5
  done
  return 1
}

echo "::group::Deploy $TAG to $INSTANCE_ID"
if ! run_remote "hello-devops-deploy '$TAG'"; then
  echo "::endgroup::"
  die "deploy of $TAG failed on the instance; the host restored the previous container"
fi
echo "::endgroup::"

echo "::group::Smoke test $URL"
if smoke_test; then
  echo "::endgroup::"
  echo "### Deployed \`$TAG\` to \`$INSTANCE_ID\` — smoke test passed" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi
echo "::endgroup::"

echo "::warning::smoke test failed for $TAG — rolling back to the previous tag"
echo "::group::Rollback"
rollback_ok=true
run_remote "hello-devops-deploy --rollback" || rollback_ok=false
echo "::endgroup::"
echo "### ❌ $TAG failed the smoke test on \`$INSTANCE_ID\`; rollback $([[ $rollback_ok == true ]] && echo succeeded || echo FAILED)" \
  >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
die "deployment of $TAG failed smoke test; rollback $([[ $rollback_ok == true ]] && echo succeeded || echo FAILED)"
