#!/usr/bin/env bash
set -u
# Run only the missing-endpoint tests from fm-control-relaunch.test.sh

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-control-relaunch.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch.test.sh"

test_spawn_relaunch_recreates_a_missing_endpoint
test_control_relaunch_recreates_a_missing_endpoint