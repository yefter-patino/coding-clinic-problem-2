#!/usr/bin/env bash
# Local checks, same as CI. Usage: ./scripts/lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."
yamllint .
ansible-lint
ansible-playbook --syntax-check -i localhost, site.yml
ansible-playbook --syntax-check -i localhost, verify.yml
ansible-playbook --syntax-check -i localhost, tests/render.yml
echo "All checks passed."
