#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

source lib.sh

ALL_TESTS="
	test_dup_bridge
	test_dup_vxlan_self
	test_dup_vxlan_master
	test_dup_macvlan_self
	test_dup_macvlan_master
"

use_bridge()
{
	local br=$1; shift

	ip link add name "$br" up type bridge vlan_filtering 1
	defer ip link del dev "$br"
}

use_vxlan()
{
	local vx=$1; shift
	local br=$1; shift

	ip link add name "$vx" up type vxlan id 2000 dstport 4789
	defer ip link del dev "$vx"

	ip link set dev "$vx" master "$br"
	defer ip link set dev "$vx" nomaster
}

use_dummy()
{
	local dd=$1; shift

	ip link add name "$dd" up type dummy
	defer ip link del dev "$dd"
}

use_macvlan()
{
	local mv=$1; shift
	local dd=$1; shift
	local br=$1; shift

	ip link add name "$mv" up link "$dd" type macvlan mode passthru
	defer ip link del dev "$mv"

	if [[ ! -z $br ]]; then
		ip link set dev "$mv" master "$br"
		defer ip link set dev "$mv" nomaster
	fi
}

do_test_dup()
{
	local op=$1; shift
	local what=$1; shift
	local tmpf

	RET=0

	tmpf=$(mktemp)
	defer rm "$tmpf"

	defer_scope_push
		bridge monitor fdb &> "$tmpf" &
		defer kill_process $!

		bridge fdb "$op" 00:11:22:33:44:55 vlan 1 "$@"
	defer_scope_pop

	local count=$(grep -c -e 00:11:22:33:44:55 $tmpf)
	((count == 1))
	check_err $? "Got $count notifications, expected 1"

	log_test "$what $op: Duplicate notifications"
}

test_dup_bridge()
{
	use_bridge br
	do_test_dup add "bridge" dev br self
	do_test_dup del "bridge" dev br self
}

test_dup_vxlan_self()
{
	use_bridge br
	use_vxlan vx br
	do_test_dup add "vxlan" dev vx self dst 192.0.2.1
	do_test_dup del "vxlan" dev vx self dst 192.0.2.1
}

test_dup_vxlan_master()
{
	use_bridge br
	use_vxlan vx br
	do_test_dup add "vxlan master" dev vx master
	do_test_dup del "vxlan master" dev vx master
}

test_dup_macvlan_self()
{
	use_dummy dd
	use_macvlan mv dd
	do_test_dup add "macvlan self" dev mv self
	do_test_dup del "macvlan self" dev mv self
}

test_dup_macvlan_master()
{
	use_bridge br
	use_dummy dd
	use_macvlan mv dd br
	do_test_dup add "macvlan master" dev mv self
	do_test_dup del "macvlan master" dev mv self
}

cleanup()
{
	defer_scopes_cleanup
}

trap cleanup EXIT
tests_run

exit $EXIT_STATUS
