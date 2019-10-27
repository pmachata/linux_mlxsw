# SPDX-License-Identifier: GPL-2.0

# Global interface:
#  $put -- port under test (e.g. $swp2)
#  get_stats($band) -- A function to collect stats for band
#  ets_start_traffic($band) -- Start traffic for this band

HAVE_QDISC=0
declare -a WS=(0 0 0)
PRIOSHIFT=0 # xxx finish prioshift support

__strict_eval()
{
	local desc=$1; shift
	local d=$1; shift
	local total=$1; shift
	local above=$1; shift

	RET=0

	if ((! total)); then
		check_err 1 "No traffic observed"
		log_test "$desc"
		return
	fi

	local ratio=$(echo "scale=2; 100 * $d / $total" | bc -l)
	if ((above)); then
		test $(echo "$ratio > 99.0" | bc -l) -eq 1
		check_err $? "Not enough traffic"
		log_test "$desc"
		log_info "Expected ratio >99% Measured ratio $ratio"
	else
		test $(echo "$ratio < 1" | bc -l) -eq 1
		check_err $? "Too much traffic"
		log_test "$desc"
		log_info "Expected ratio <1% Measured ratio $ratio"
	fi
}

strict_eval()
{
	__strict_eval "$@" 1
}

notraf_eval()
{
	__strict_eval "$@" 0
}

__ets_dwrr_test()
{
	local -a streams=("$@")

	local low_stream=${streams[0]}
	local seen_strict=0
	local -a t0 t1 d
	local stream
	local total
	local i

	echo "Testing ETS ${WS[@]}, streams ${streams[@]}"

	for stream in ${streams[@]}; do
		ets_start_traffic $stream
	done

	sleep 10

	t0=($(for stream in ${streams[@]}; do
		  get_stats $stream
	      done))

	sleep 10

	t1=($(for stream in ${streams[@]}; do
		  get_stats $stream
	      done))
	d=($(for ((i = 0; i < ${#streams[@]}; i++)); do
		 echo $((${t1[$i]} - ${t0[$i]}))
	     done))
	total=$(echo ${d[@]} | sed 's/ /+/g' | bc)

	# xxx check total traffic

	for ((i = 0; i < ${#streams[@]}; i++)); do
		local stream=${streams[$i]}
		if ((seen_strict)); then
			notraf_eval "band $stream" ${d[$i]} $total
		elif ((${WS[$stream]} == 0)); then
			# xxx WS is by band, not by stream.
			# xxx This doesn't add up.
			strict_eval "band $stream" ${d[$i]} $total
			seen_strict=1
		elif ((stream == low_stream)); then
			# Low stream is used as DWRR evaluation reference.
			continue
		else
			multipath_eval "bands $low_stream:$stream" \
				       ${WS[$low_stream]} ${WS[$stream]} \
				       ${d[0]} ${d[$i]}
		fi
	done

	for stream in ${streams[@]}; do
		stop_traffic
	done
}

ets_dwrr_test_012()
{
	__ets_dwrr_test 0 1 2
}

ets_dwrr_test_01()
{
	__ets_dwrr_test 0 1
}

ets_dwrr_test_12()
{
	__ets_dwrr_test 1 2
}

ets_qdisc_setup()
{
	local dev=$1; shift
	local nstrict=$1; shift
	local prioshift=$1; shift
	local -a quanta=("$@")

	local op=$(if ((HAVE_QDISC)); then echo change; else echo add; fi)
	local ndwrr=${#quanta[@]}
	local nbands=$((nstrict + ndwrr))
	local nstreams=$(if ((nbands > 3)); then echo 3; else echo $nbands; fi)
	local priomap=$(seq $prioshift $((prioshift + nstreams - 1)))
	local i

	WS=($(
		for ((i = 0; i < nstrict; i++)); do
			echo 0
		done
		for ((i = 0; i < ndwrr; i++)); do
			echo ${quanta[$i]}
		done
	))

	tc qdisc $op dev $dev $PARENT handle 10: ets			       \
		$(if ((nstrict)); then echo strict $nstrict; fi)	       \
		$(if ((${#quanta[@]})); then echo quanta ${quanta[@]}; fi)     \
		priomap $priomap
	HAVE_QDISC=1
	PRIOSHIFT=$prioshift
}

ets_set_dwrr_uniform()
{
	ets_qdisc_setup $put 0 0 3300 3300 3300
}

ets_set_dwrr_varying()
{
	ets_qdisc_setup $put 0 0 5000 3500 1500
}

ets_set_strict()
{
	ets_qdisc_setup $put 3 0
}

ets_set_mixed()
{
	ets_qdisc_setup $put 1 0 5000 2500 1500
}

ets_change_quantum()
{
	tc class change dev $put classid 10:2 ets quantum 8000
	WS[1]=8000
}

ets_set_dwrr_two_bands()
{
	ets_qdisc_setup $put 0 0 5000 2500
}
