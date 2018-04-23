#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# This test uses standard topology for testing gretap. See
# mirror_gre_topo_lib.sh for more details.
#
# Test for "tc action mirred egress mirror" when the underlay route points at a
# bridge device with vlan filtering (802.1q).

NUM_NETIFS=6
source lib.sh
source mirror_lib.sh
source mirror_gre_lib.sh
source mirror_gre_topo_lib.sh

setup_prepare()
{
	h1=${NETIFS[p1]}
	swp1=${NETIFS[p2]}

	swp2=${NETIFS[p3]}
	h2=${NETIFS[p4]}

	swp3=${NETIFS[p5]}
	h3=${NETIFS[p6]}

	vrf_prepare
	mirror_gre_topo_create

	ip link set dev $swp3 master br1
	ip route add 192.0.2.130/32 dev br1
	ip -6 route add 2001:db8:2::2/128 dev br1

	ip address add dev br1 192.0.2.129/32
	ip address add dev br1 2001:db8:2::1/128

	ip link add name $h3.555 link $h3 type vlan id 555
	ip link set dev $h3.555 master v$h3
	ip address add dev $h3.555 192.0.2.130/28
	ip address add dev $h3.555 2001:db8:2::2/64
	ip link set dev $h3.555 up

	bridge vlan add dev br1 vid 555 pvid untagged self
	bridge vlan add dev $swp3 vid 555
}

cleanup()
{
	pre_cleanup

	ip link del dev $h3.555

	mirror_gre_topo_destroy
	vrf_cleanup
}

tests()
{
	slow_path_trap_install $swp1 ingress
	slow_path_trap_install $swp1 egress

	mirror_install $swp1 ingress gt4 "matchall $tcflags"
	read -p Ready.
	mirror_uninstall $swp1 ingress

	slow_path_trap_uninstall $swp1 egress
	slow_path_trap_uninstall $swp1 ingress
}

trap cleanup EXIT

setup_prepare
setup_wait

# tcflags="skip_hw"
# tests

if ! tc_offload_check; then
	echo "WARN: Could not test offloaded functionality"
else
	tcflags="skip_sw"
	tests
fi

exit $EXIT_STATUS
