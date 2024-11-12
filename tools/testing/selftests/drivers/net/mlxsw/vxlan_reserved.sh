#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

vxlan_reserved_setup_hook()
{
	tc qdisc add dev $swp1 clsact
	defer tc qdisc del dev $swp1 clsact

	tc filter add dev $swp1 egress pref 77 prot ip flower skip_hw action pass
	defer tc filter del dev $swp1 egress pref 77
}

vxlan_reserved_test_hook()
{
	local ret
	local t0=$(tc_rule_stats_get $swp1 77 egress)
	"$@"
	ret=$?
	local t1=$(tc_rule_stats_get $swp1 77 egress)

	RET=0
	# Packets should either go through fast path, or be dropped by the vxlan
	# netdevice. Nothing should pass through the slow path.
	local expect=0
	local delta=$((t1 - t0))
	((expect == delta))
	check_err $? "Expected $expect slow-path packets, got $delta."
	log_test "$what: slow-path packets"

	return $ret
}

lib_dir=$(dirname $0)/../../../net/forwarding
source $lib_dir/vxlan_reserved.sh
