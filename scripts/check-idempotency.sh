#!/usr/bin/env bash
# Runs the playbook twice. The second run must report changed=0 on every host.
# Usage: ./scripts/check-idempotency.sh [extra ansible-playbook args, e.g. -e target_hosts=env_dev]
set -euo pipefail
cd "$(dirname "$0")/.."
ansible-playbook site.yml "$@"
second_run="$(ansible-playbook site.yml "$@" | tee /dev/stderr)"
if echo "$second_run" | grep -E 'changed=[1-9]' >/dev/null; then
  echo "NOT idempotent: the second run changed something." >&2
  exit 1
fi
echo "Idempotent: second run changed nothing."
