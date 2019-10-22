#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# A driver for the ETS selftest that implements testing in offloaded datapath.
lib_dir=$(dirname $0)/../../../net/forwarding
source $lib_dir/sch_ets_core.sh
source $lib_dir/devlink_lib.sh
source qos_lib.sh

switch_create()
{
	ets_switch_create

	# Create a bottleneck so that the DWRR process can kick in.
	ethtool -s $h2 speed 1000 autoneg off
	ethtool -s $swp2 speed 1000 autoneg off

	# Set the ingress quota high and use the three egress TCs to limit the
	# amount of traffic that is admitted to the shared buffers. This makes
	# sure that there is always enough traffic of all types to select from
	# for the DWRR process.

	devlink_port_pool_th_set $swp1 0 12
	devlink_tc_bind_pool_th_set $swp1 0 ingress 0 12
	devlink_port_pool_th_set $swp2 4 12
	devlink_tc_bind_pool_th_set $swp2 7 egress 4 5
	devlink_tc_bind_pool_th_set $swp2 6 egress 4 5
	devlink_tc_bind_pool_th_set $swp2 5 egress 4 5
}

switch_destroy()
{
	devlink_tc_bind_pool_th_restore $swp2 5 egress
	devlink_tc_bind_pool_th_restore $swp2 6 egress
	devlink_tc_bind_pool_th_restore $swp2 7 egress
	devlink_port_pool_th_restore $swp2 4
	devlink_tc_bind_pool_th_restore $swp1 0 ingress
	devlink_port_pool_th_restore $swp1 0

	ethtool -s $swp2 autoneg on
	ethtool -s $h2 autoneg on

	ets_switch_destroy
}

get_stats()
{
	local dev=$1; shift
	local band=$1; shift

	ethtool_stats_get "$dev" rx_octets_prio_$band
}

bail_on_lldpad
ets_run
