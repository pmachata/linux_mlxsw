#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# +------------------------+                           +-----------------------+
# | H1 (vrf)               |                           |             H2 (vrf)  |
# |                  $h1 +-------------------------------+ $h2                 |
# |                     /| |                           | |\                    |
# |            $h1.101 + | |                           | | + $h2.101           |
# |       192.0.2.1/30   | |                           | |   192.0.2.2/30      |
# |   2001:db8:1::1/64   | |                           | |   2001:db8:1::2/64  |
# |                     /| |                           | |\                    |
# |            $h1.102 + | |                           | | + $h2.102           |
# |       192.0.2.5/30   | |                           | |   192.0.2.6/30      |
# |   2001:db8:2::1/64   | |                           | |   2001:db8:2::2/64  |
# |                     /| |                           | |\                    |
# |            $h1.103 + | |                           | | + $h2.103           |
# |       192.0.2.9/30   | |                           | |   192.0.2.10/30     |
# |   2001:db8:3::1/64   | |                           | |   2001:db8:3::2/64  |
# |                      | |                           | |                     |
# |         . . .        | |                           | |       . . .         |
# |                      | |                           | |                     |
# |                     /  |                           |  \                    |
# |            $h1.164 +   |                           |   + $h2.164           |
# |     192.0.2.253/30     |                           |     192.0.2.254/30    |
# |  2001:db8:64::1/64     |                           |     2001:db8:64::2/64 |
# +------------------------+                           +-----------------------+
#
# +------------------------+                           +-----------------------+
# | H3 (vrf)         $h3 +-------------------------------+ $h4       H4 (vrf)  |
# |         . . .          |                           |         . . .         |
# +------------------------+                           +-----------------------+
#
# +------------------------+                           +-----------------------+
# | H5 (vrf)         $h5 +-------------------------------+ $h6       H6 (vrf)  |
# +------------------------+                           +-----------------------+
# | H7 (vrf)         $h7 +-------------------------------+ $h8       H8 (vrf)  |
# +------------------------+                           +-----------------------+

ALL_TESTS="
	bfd
"
NUM_NETIFS=8
source lib.sh

T=100ms

add_session_pair()
{
    local n=$1; shift

    local h=$((n % 4)) # host pair
    local i=$((n / 4)) # session n. on host
    local ipv=$((i % 2 ? 6 : 4)) # ipv4 / ipv6
    local dev=$((i / 2)) # VLAN device n.
    local vid=$((100 + dev))

    local lpn="h$((2 * h + 1))"
    local rpn="h$((2 * h + 2))"
    local lp=${!lpn}
    local rp=${!rpn}
    local lvrf="v$lp"
    local rvrf="v$rp"
    local ldev="$lp.$vid"
    local rdev="$rp.$vid"

    local num
    local schema
    local mask

    if ! ip link show dev "$ldev" &>/dev/null; then
	adf_vlan_create "$lp" "$vid" "$lvrf"
	adf_vlan_create "$rp" "$vid" "$rvrf"
    fi

    if ((ipv == 4)); then
	num=$((dev * 4 + 1)) # host number in IPv4 address
	mask=30
	schema=192.0.2.%d

	if ((num >= 256)); then
	    schema=192.168.0.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.100.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.101.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.102.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.103.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.104.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.105.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.106.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.107.%d
	    ((num -= 256))
	fi

	if ((num >= 256)); then
	    schema=10.100.108.%d
	    ((num -= 256))
	fi
    else
	schema="2001:db8:$dev::%x"
	mask=64
	num=1
    fi

    local src=$(printf "$schema" $((num)))
    local dst=$(printf "$schema" $((num + 1)))

    adf_ip_addr_add "$ldev" "$src/$mask"
    adf_ip_addr_add "$rdev" "$dst/$mask"

    bbdd session add vrf "$lvrf" src "$src" dst "$dst" \
	 min-tx "$T" min-rx "$T" detect-mult 3

    bbdd session add vrf "$rvrf" src "$dst" dst "$src" \
	 min-tx "$T" min-rx "$T" detect-mult 3
}

adf_systemctl_start()
{
	local unit=$1; shift

	systemctl start "$unit"
	if (($?)); then
                check_err 1
                log_test "systemctl start"
		exit $EXIT_STATUS
	fi

	slowwait 2 systemctl is-active --quiet "$unit"
	if (($?)); then
                check_err 1
                log_test "systemctl start"
		exit $EXIT_STATUS
	fi

	log_info "$unit started"
	defer systemctl stop "$unit"
}

setup_prepare()
{
	local i

	adf_vrf_prepare
	adf_forwarding_enable

	adf_systemctl_start bbdd
	adf_sysctl_set net.ipv4.neigh.default.gc_thresh1 4096
	adf_sysctl_set net.ipv4.neigh.default.gc_thresh2 6144
	adf_sysctl_set net.ipv4.neigh.default.gc_thresh3 8192
	adf_sysctl_set net.ipv6.neigh.default.gc_thresh1 4096
	adf_sysctl_set net.ipv6.neigh.default.gc_thresh2 6144
	adf_sysctl_set net.ipv6.neigh.default.gc_thresh3 8192

	h1=${NETIFS[p1]}
	h2=${NETIFS[p2]}
	h3=${NETIFS[p3]}
	h4=${NETIFS[p4]}
	h5=${NETIFS[p5]}
	h6=${NETIFS[p6]}
	h7=${NETIFS[p7]}
	h8=${NETIFS[p8]}

	adf_simple_if_init "$h1"
	adf_simple_if_init "$h2"
	adf_simple_if_init "$h3"
	adf_simple_if_init "$h4"
	adf_simple_if_init "$h5"
	adf_simple_if_init "$h6"
	adf_simple_if_init "$h7"
	adf_simple_if_init "$h8"

	# devlink -s trap policer set pci/0000:06:00.0 policer 8 rate 150000

	defer bbdd session bulk del
	for ((i=0; i<3979; i++)); do
		add_session_pair "$i"
	done
}

bfd()
{
	sleep 2
	bbdd session show
	read -p Ready.
}

trap cleanup EXIT
setup_prepare
setup_wait
tests_run
exit $EXIT_STATUS
