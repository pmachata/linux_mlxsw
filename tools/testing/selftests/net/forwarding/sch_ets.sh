#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# A driver for the ETS selftest that implements testing in slowpath.
lib_dir=.
source sch_ets_core.sh

switch_create()
{
	ets_switch_create

	# Create a bottleneck so that the DWRR process can kick in.
	tc qdisc add dev $swp2 root handle 1: tbf \
	   rate 1Gbit burst 1Mbit latency 100ms
	PARENT="parent 1:"
}

switch_destroy()
{
	ets_switch_destroy
}

get_stats()
{
	local band=$1; shift

	link_stats_get $h2.1$i rx bytes
}

ets_run
