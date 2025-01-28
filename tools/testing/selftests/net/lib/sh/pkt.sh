# SPDX-License-Identifier: GPL-2.0

pkt_ipv4_to_bytes()
{
	local IP=$1; shift

	printf '%02x:' ${IP//./ } |
	    sed 's/:$//'
}

# Convert a given IPv6 address, `IP' such that the :: token, if present, is
# expanded, and each 16-bit group is padded with zeroes to be 4 hexadecimal
# digits. An optional `BYTESEP' parameter can be given to further separate
# individual bytes of each 16-bit group.
pkt_expand_ipv6()
{
	local IP=$1; shift
	local bytesep=$1; shift

	local cvt_ip=${IP/::/_}
	local colons=${cvt_ip//[^:]/}
	local allcol=:::::::
	# IP where :: -> the appropriate number of colons:
	local allcol_ip=${cvt_ip/_/${allcol:${#colons}}}

	echo $allcol_ip | tr : '\n' |
	    sed s/^/0000/ |
	    sed 's/.*\(..\)\(..\)/\1'"$bytesep"'\2/' |
	    tr '\n' : |
	    sed 's/:$//'
}

pkt_ipv6_to_bytes()
{
	local IP=$1; shift

	pkt_expand_ipv6 "$IP" :
}

pkt_u16_to_bytes()
{
	local u16=$1; shift

	printf "%04x" $u16 | sed 's/^/000/;s/^.*\(..\)\(..\)$/\1:\2/'
}

# Given a mausezahn-formatted payload (colon-separated bytes given as %02x),
# possibly with a keyword CHECKSUM stashed where a 16-bit checksum should be,
# calculate checksum as per RFC 1071, assuming the CHECKSUM field (if any)
# stands for 00:00.
pkt_payload_template_calc_checksum()
{
	local payload=$1; shift

	(
	    # Set input radix.
	    echo "16i"
	    # Push zero for the initial checksum.
	    echo 0

	    # Pad the payload with a terminating 00: in case we get an odd
	    # number of bytes.
	    echo "${payload%:}:00:" |
		sed 's/CHECKSUM/00:00/g' |
		tr '[:lower:]' '[:upper:]' |
		# Add the word to the checksum.
		sed 's/\(..\):\(..\):/\1\2+\n/g' |
		# Strip the extra odd byte we pushed if left unconverted.
		sed 's/\(..\):$//'

	    echo "10000 ~ +"	# Calculate and add carry.
	    echo "FFFF r - p"	# Bit-flip and print.
	) |
	    dc |
	    tr '[:upper:]' '[:lower:]'
}

pkt_payload_template_expand_checksum()
{
	local payload=$1; shift
	local checksum=$1; shift

	local ckbytes=$(pkt_u16_to_bytes $checksum)

	echo "$payload" | sed "s/CHECKSUM/$ckbytes/g"
}

pkt_payload_template_nbytes()
{
	local payload=$1; shift

	pkt_payload_template_expand_checksum "${payload%:}" 0 |
		sed 's/:/\n/g' | wc -l
}

pkt_igmpv3_is_in_get()
{
	local GRP=$1; shift
	local sources=("$@")

	local igmpv3
	local nsources=$(pkt_u16_to_bytes ${#sources[@]})

	# IS_IN ( $sources )
	igmpv3=$(:
		)"22:"$(			: Type - Membership Report
		)"00:"$(			: Reserved
		)"CHECKSUM:"$(			: Checksum
		)"00:00:"$(			: Reserved
		)"00:01:"$(			: Number of Group Records
		)"01:"$(			: Record Type - IS_IN
		)"00:"$(			: Aux Data Len
		)"${nsources}:"$(		: Number of Sources
		)"$(pkt_ipv4_to_bytes $GRP):"$(	: Multicast Address
		)"$(for src in "${sources[@]}"; do
			pkt_ipv4_to_bytes $src
			echo -n :
		    done)"$(			: Source Addresses
		)
	local checksum=$(pkt_payload_template_calc_checksum "$igmpv3")

	pkt_payload_template_expand_checksum "$igmpv3" $checksum
}

pkt_igmpv2_leave_get()
{
	local GRP=$1; shift

	local payload=$(:
		)"17:"$(			: Type - Leave Group
		)"00:"$(			: Max Resp Time - not meaningful
		)"CHECKSUM:"$(			: Checksum
		)"$(pkt_ipv4_to_bytes $GRP)"$(	: Group Address
		)
	local checksum=$(pkt_payload_template_calc_checksum "$payload")

	pkt_payload_template_expand_checksum "$payload" $checksum
}

pkt_mldv2_is_in_get()
{
	local SIP=$1; shift
	local GRP=$1; shift
	local sources=("$@")

	local hbh
	local icmpv6
	local nsources=$(pkt_u16_to_bytes ${#sources[@]})

	hbh=$(:
		)"3a:"$(			: Next Header - ICMPv6
		)"00:"$(			: Hdr Ext Len
		)"00:00:00:00:00:00:"$(		: Options and Padding
		)

	icmpv6=$(:
		)"8f:"$(			: Type - MLDv2 Report
		)"00:"$(			: Code
		)"CHECKSUM:"$(			: Checksum
		)"00:00:"$(			: Reserved
		)"00:01:"$(			: Number of Group Records
		)"01:"$(			: Record Type - IS_IN
		)"00:"$(			: Aux Data Len
		)"${nsources}:"$(		: Number of Sources
		)"$(pkt_ipv6_to_bytes $GRP):"$(	: Multicast address
		)"$(for src in "${sources[@]}"; do
			pkt_ipv6_to_bytes $src
			echo -n :
		    done)"$(			: Source Addresses
		)

	local len=$(pkt_u16_to_bytes $(pkt_payload_template_nbytes $icmpv6))
	local sudohdr=$(:
		)"$(pkt_ipv6_to_bytes $SIP):"$(	: SIP
		)"$(pkt_ipv6_to_bytes $GRP):"$(	: DIP is multicast address
	        )"${len}:"$(			: Upper-layer length
	        )"00:3a:"$(			: Zero and next-header
	        )
	local checksum=$(pkt_payload_template_calc_checksum ${sudohdr}${icmpv6})

	pkt_payload_template_expand_checksum "$hbh$icmpv6" $checksum
}

pkt_mldv1_done_get()
{
	local SIP=$1; shift
	local GRP=$1; shift

	local hbh
	local icmpv6

	hbh=$(:
		)"3a:"$(			: Next Header - ICMPv6
		)"00:"$(			: Hdr Ext Len
		)"00:00:00:00:00:00:"$(		: Options and Padding
		)

	icmpv6=$(:
		)"84:"$(			: Type - MLDv1 Done
		)"00:"$(			: Code
		)"CHECKSUM:"$(			: Checksum
		)"00:00:"$(			: Max Resp Delay - not meaningful
		)"00:00:"$(			: Reserved
		)"$(pkt_ipv6_to_bytes $GRP):"$(	: Multicast address
		)

	local len=$(pkt_u16_to_bytes $(pkt_payload_template_nbytes $icmpv6))
	local sudohdr=$(:
		)"$(pkt_ipv6_to_bytes $SIP):"$(	: SIP
		)"$(pkt_ipv6_to_bytes $GRP):"$(	: DIP is multicast address
	        )"${len}:"$(			: Upper-layer length
	        )"00:3a:"$(			: Zero and next-header
	        )
	local checksum=$(pkt_payload_template_calc_checksum ${sudohdr}${icmpv6})

	pkt_payload_template_expand_checksum "$hbh$icmpv6" $checksum
}

pkt_igmpv3_query_get()
{
	local GRP=$1; shift
	local sources=("$@")

	local igmpv3
	local nsources=$(pkt_u16_to_bytes ${#sources[@]})

	# QUERY ( $sources )
	igmpv3=$(:
		)"11:"$(			: Type - Membership Query
		)"00:"$(			: Max Resp Code
		)"CHECKSUM:"$(			: Checksum
		)"$(pkt_ipv4_to_bytes $GRP):"$(	: Group Address
		)"00:"$(			: Rsv / S / QRV
		)"00:"$(			: QQIC
		)"${nsources}:"$(		: Number of Sources
		)"$(for src in "${sources[@]}"; do
			pkt_ipv4_to_bytes $src
			echo -n :
		    done)"$(			: Source Addresses
		)
	local checksum=$(pkt_payload_template_calc_checksum "$igmpv3")

	pkt_payload_template_expand_checksum "$igmpv3" $checksum
}

pkt_igmpv3_parse_records()
{
	# This is how tcpdump shows membership reports (all in one line):
	#   192.0.2.1 > 224.0.0.22: igmp v3 report, 2 group record(s)
	#   [gaddr 224.0.1.6 is_ex, 0 source(s)]
	#   [gaddr 224.0.0.5 is_ex, 0 source(s)]

	grep 'igmp v3 report' |
	    grep -o '\[[^]]*]' |
	    cut -d' ' -f 2,3 |
	    tr -d ,
}
