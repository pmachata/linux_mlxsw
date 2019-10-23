# SPDX-License-Identifier: GPL-2.0

# Global interface:
#  $put -- port under test (e.g. $swp2)
#  get_stats($band) -- A function to collect stats for band
#  ets_start_traffic($band) -- Start traffic for this band

HAVE_QDISC=false
declare -a WS=(0 0 0)

__ets_dwrr_test()
{
	local n=$1; shift

	local is=$(seq 0 $((n - 1)))
	local -a t0 t1 d
	local i

	for i in $is; do
		ets_start_traffic $i
	done

	sleep 10

	t0=($(for i in $is; do
		  get_stats $i
	      done))

	sleep 10

	t1=($(for i in $is; do
		  get_stats $i
	      done))
	d=($(for i in $is; do
		 echo $((${t1[$i]} - ${t0[$i]}))
	     done))

	for i in $(seq $((n - 1))); do
		multipath_eval "bands 0:$i" ${WS[0]} ${WS[$i]} ${d[0]} ${d[$i]}
	done

	for i in $is; do
		stop_traffic
	done
}

ets_dwrr_test3()
{
	echo "Testing ETS DRR weights ${WS[0]} ${WS[1]} ${WS[2]}"
	__ets_dwrr_test 3
}

ets_dwrr_test2()
{
	echo "Testing ETS DRR weights ${WS[0]} ${WS[1]}"
	__ets_dwrr_test 2
}

ets_qdisc_setup()
{
	local dev=$1; shift
	local -a quanta=("$@")

	local op=$(if $HAVE_QDISC; then echo change; else echo add; fi)
	local n=${#quanta[@]}
	local is=$(seq 0 $((n - 1)))
	local i

	for ((i = 0; i < n; i++)); do
		WS[$i]=${quanta[$i]}
	done
	for ((; i < ${#WS[@]}; i++)); do
		WS[$i]=0
	done

	tc qdisc $op dev $dev $PARENT handle 10: ets \
	   quanta ${quanta[@]} priomap $is
	HAVE_QDISC=true
}

ets_set_dwrr_uniform()
{
	ets_qdisc_setup $put 3300 3300 3300
}

ets_set_dwrr_varying()
{
	ets_qdisc_setup $put 5000 3500 1500
}

ets_change_class()
{
	tc class change dev $put classid 10:2 ets quantum 8000
	WS[1]=8000
}

ets_set_dwrr_two_bands()
{
	ets_qdisc_setup $put 5000 2500
}
