#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

source lib.sh

ALL_TESTS="
	test_changelink
"

setup_prepare()
{
	ip link add name vx up type vxlan id 2000 dstport 4789
	defer ip link del dev vx
}

check_remotes()
{
	local what=$1; shift
	local N=$(bridge fdb sh dev vx | grep 00:00:00:00:00:00 | wc -l)

	((N == 2))
	check_err $? "Got $N FDB entries, expected 2"
}

test_changelink()
{
	# Check FDB default-remote handling across "ip link set".

	RET=0

	bridge fdb ap dev vx 00:00:00:00:00:00 dst 192.0.2.20 self permanent
	bridge fdb ap dev vx 00:00:00:00:00:00 dst 192.0.2.30 self permanent
	check_remotes "fdb append"

	ip link set dev vx type vxlan remote 192.0.2.30
	check_remotes "link set"

	log_test "vxlan: Default FDB entry retained across changelink"
}

cleanup()
{
	defer_scopes_cleanup
}

trap cleanup EXIT
setup_prepare
tests_run

exit $EXIT_STATUS
