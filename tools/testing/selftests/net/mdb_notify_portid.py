#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""
Check that bridge MDB notifications carry the netlink port ID of the requester
in nlmsg_pid. A listener socket subscribed to the MDB group receives the
notifications, while separate requester sockets make the changes. The port ID
the listener sees is expected to match that of the requester socket. Changes
that are not a result of a request, such as those made by IGMP snooping or by
a timer, are expected to carry zero.
"""

import socket
import struct
from collections import namedtuple

from lib.py import ksft_run, ksft_exit, ksft_eq, ksft_ne, ksft_true
from lib.py import ksft_busy_wait
from lib.py import ip
from lib.py import NetNS, NetNSEnter
from lib.py import Netlink, RtnlMdbFamily

RTM_NEWMDB = 84
RTM_DELMDB = 85

MDB_TEMPORARY = 0
MDB_PERMANENT = 1

MCAST_EXCLUDE = 0
MCAST_INCLUDE = 1

ETH_P_IP = 0x0800

Ntf = namedtuple("Ntf", "type portid group")


class Env:
    """The listener socket, the two requester sockets A and B, and the
    netlink port IDs of the latter. All sockets live in the given netns."""

    @staticmethod
    def _socket(ns):
        with NetNSEnter(ns):
            rtnl = RtnlMdbFamily()
        return rtnl

    def __init__(self, ns):
        self.ns = str(ns)

        self.listener = self._socket(ns)
        self.listener.include_raw = True
        self.listener.ntf_subscribe("rtnlgrp-mdb")

        self.a = self._socket(ns)
        self.a.sock.bind((0, 0))

        self.b = self._socket(ns)
        self.b.sock.bind((0, 0))

        self.portids = {self.a: self.a.sock.getsockname()[0],
                        self.b: self.b.sock.getsockname()[0]}

        ksft_ne(self.portids[self.a], self.portids[self.b])
        ksft_ne(self.portids[self.a], 0)

    def ifindex(self, name):
        """Look up the ifindex of a device in the test netns."""
        with NetNSEnter(self.ns):
            return socket.if_nametoindex(name)

    def ntfs(self):
        """Return the entry notifications received by the listener."""
        self.listener.check_ntf()
        ntfs = []
        while self.listener.async_msg_queue.qsize() > 0:
            msg = self.listener.async_msg_queue.get()
            if 'mdb' not in msg['msg']:
                continue    # Router port notification.
            for ent in msg['msg']['mdb']['entry']:
                ntfs.append(Ntf(msg['raw'].nl_type, msg['raw'].nl_portid,
                                group_str(ent['info'])))
        return ntfs

    def check_ntfs(self, nl_type, group, requester, count=1):
        """Expect count notifications for group, all from the requester."""
        portids = [n.portid for n in self.ntfs()
                   if n.type == nl_type and n.group == group]
        ksft_eq(portids, [self.portids[requester]] * count,
                f"nlmsg_pid of {group} notifications")


def check_pids(env, group, requester, count=None):
    """Expect notifications of any type for group, all from the requester.
    Unless COUNT is given, any non-zero number of them is fine."""
    portids = [n.portid for n in env.ntfs() if n.group == group]
    ksft_true(portids and (count is None or len(portids) == count),
              f"Expected notifications for {group}, got {portids}")
    ksft_eq(set(portids), {env.portids[requester]},
            f"nlmsg_pid of {group} notifications")


def group_str(info):
    """Format the group address of a notified entry."""
    if info['proto'] == ETH_P_IP:
        return socket.inet_ntoa(info['addr'][:4])
    return socket.inet_ntop(socket.AF_INET6, info['addr'])


def mdb_req(bridge_ifindex, ifindex, group, state, attrs=None):
    """Build a request to add or delete a group entry. IFINDEX is that of the
    bridge port, or of the bridge itself for a host entry."""
    req = {'family': socket.AF_BRIDGE, 'ifindex': bridge_ifindex,
           'set-entry': {'ifindex': ifindex, 'state': state,
                         'addr': socket.inet_aton(group).hex() + "00" * 12,
                         'proto': ETH_P_IP}}
    if attrs:
        req['set-entry-attrs'] = attrs
    return req


def src_list(sources, mode=MCAST_INCLUDE):
    """Build the attributes that give a (*,G) entry a filter mode and a list
    of sources."""
    return {'group-mode': mode,
            'src-list': {'entry': [{'address': s} for s in sources]}}


def add_replace_del(env, br, port, group, *, count=1, attrs=None):
    """Add an entry through socket A, replace it through B, delete it through
    A. The replace step is skipped for host entries, which cannot be changed
    other than by deleting them, and for entries that have sources."""
    bridge_ifindex = env.ifindex(br)
    ifindex = env.ifindex(port)
    host = port == br

    env.a.do('newmdb',
             mdb_req(bridge_ifindex, ifindex, group, MDB_TEMPORARY, attrs),
             flags=[Netlink.NLM_F_CREATE | Netlink.NLM_F_EXCL])
    env.check_ntfs(RTM_NEWMDB, group, env.a, count)

    if not host and not attrs:
        env.b.do('newmdb',
                 mdb_req(bridge_ifindex, ifindex, group, MDB_PERMANENT),
                 flags=[Netlink.NLM_F_CREATE | Netlink.NLM_F_REPLACE])
        env.check_ntfs(RTM_NEWMDB, group, env.b, count)

    state = MDB_TEMPORARY if host else MDB_PERMANENT
    env.a.do('delmdb',
             mdb_req(bridge_ifindex, ifindex, group, state),
             flags=[])
    env.check_ntfs(RTM_DELMDB, group, env.a, count)


def test_bridge() -> None:
    """A bridge port group: add, replace, delete."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)
        ip("link add d0 up type dummy", ns=ns)
        ip("link set dev d0 master br0", ns=ns)

        add_replace_del(env, "br0", "d0", "239.1.1.1")


def test_bridge_host() -> None:
    """A host group, i.e. one joined by the bridge device itself."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)

        add_replace_del(env, "br0", "br0", "239.1.1.2")


def test_bridge_sources() -> None:
    """An INCLUDE-mode (*,G) entry with sources: adding it creates an (S,G)
    entry for each source, and deleting it deletes them. All of the
    resulting notifications carry the port ID of the requester."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)
        ip("link add d0 up type dummy", ns=ns)
        ip("link set dev d0 master br0", ns=ns)

        add_replace_del(env, "br0", "d0", "239.1.1.3", count=3,
                        attrs=src_list(["192.0.2.1", "192.0.2.2"]))


def test_bridge_exclude() -> None:
    """Changing the filter mode of a (*,G) entry affects the (S,G) entries
    that exist for the group, and the resulting notifications carry the port
    ID of the requester as well."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)
        ip("link add d0 up type dummy", ns=ns)
        ip("link add d1 up type dummy", ns=ns)
        ip("link set dev d0 master br0", ns=ns)
        ip("link set dev d1 master br0", ns=ns)

        br = env.ifindex("br0")
        d0 = env.ifindex("d0")
        d1 = env.ifindex("d1")
        group = "239.1.1.4"

        create = [Netlink.NLM_F_CREATE | Netlink.NLM_F_EXCL]
        replace = [Netlink.NLM_F_CREATE | Netlink.NLM_F_REPLACE]

        def request(sock, op, port, attrs, flags):
            env.ntfs()
            sock.do(op, mdb_req(br, port, group, MDB_PERMANENT, attrs),
                    flags=flags)
            check_pids(env, group, sock)

        request(env.a, 'newmdb', d0, {'source': "192.0.2.1"}, create)
        request(env.a, 'newmdb', d1, src_list([], MCAST_EXCLUDE), create)
        request(env.b, 'newmdb', d1,
                src_list(["192.0.2.2"], MCAST_INCLUDE), replace)
        request(env.a, 'newmdb', d1, src_list([], MCAST_EXCLUDE), replace)
        request(env.b, 'delmdb', d1, None, [])
        request(env.b, 'delmdb', d0, {'source': "192.0.2.1"}, [])


def flush(env, br, port, groups):
    """Flush all entries of a port through socket A, and check that all the
    notifications carry the port ID. Host entries are always temporary."""
    bridge_ifindex = env.ifindex(br)
    ifindex = env.ifindex(port)
    state = MDB_TEMPORARY if port == br else MDB_PERMANENT

    for group in groups:
        env.a.do('newmdb',
                 mdb_req(bridge_ifindex, ifindex, group, state),
                 flags=[Netlink.NLM_F_CREATE | Netlink.NLM_F_EXCL])

    env.ntfs()

    # A bulk request carries an all-zeroes address, i.e. any group.
    req = mdb_req(bridge_ifindex, ifindex, "0.0.0.0", state)
    req['set-entry']['proto'] = 0
    env.a.do('delmdb', req, flags=[Netlink.NLM_F_BULK])

    ntfs = [n for n in env.ntfs() if n.type == RTM_DELMDB]

    ksft_true({n.group for n in ntfs} >= set(groups),
              "Flush did not notify about all the entries")
    ksft_eq({n.portid for n in ntfs}, {env.portids[env.a]},
            "nlmsg_pid of flush notifications")


def test_bridge_flush() -> None:
    """Bulk delete of bridge port entries."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)
        ip("link add d0 up type dummy", ns=ns)
        ip("link set dev d0 master br0", ns=ns)

        flush(env, "br0", "d0", ["239.2.2.1", "239.2.2.2", "239.2.2.3"])


def test_bridge_flush_host() -> None:
    """Bulk delete of host entries."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge vlan_default_pvid 0", ns=ns)

        flush(env, "br0", "br0", ["239.2.2.4", "239.2.2.5"])


def test_bridge_timer() -> None:
    """A temporary entry that times out is deleted by the bridge, not as a
    result of a request, and the notification carries port ID of zero."""
    with NetNS() as ns:
        env = Env(ns)

        # The interval is in units of 1/100 s.
        ip("link add br0 up type bridge vlan_default_pvid 0 "
           "mcast_membership_interval 100", ns=ns)
        ip("link add d0 up type dummy", ns=ns)
        ip("link set dev d0 master br0", ns=ns)

        group = "239.3.1.1"
        env.a.do('newmdb',
                 mdb_req(env.ifindex("br0"), env.ifindex("d0"), group,
                         MDB_TEMPORARY),
                 flags=[Netlink.NLM_F_CREATE | Netlink.NLM_F_EXCL])
        env.check_ntfs(RTM_NEWMDB, group, env.a)

        portids = []

        def expired():
            nonlocal portids
            portids = [n.portid for n in env.ntfs()
                       if n.type == RTM_DELMDB and n.group == group]
            return portids != []

        ksft_busy_wait(expired, deadline=5)

        ksft_eq(portids, [0], "nlmsg_pid of expired entry")


def igmp_report(group):
    """Build an Ethernet frame with an IGMPv2 membership report."""
    def checksum(data):
        total = sum(struct.unpack(f"!{len(data) // 2}H", data))
        total = (total & 0xffff) + (total >> 16)
        total = (total & 0xffff) + (total >> 16)
        return ~total & 0xffff

    igmp = struct.pack("!BBH4s", 0x16, 0, 0, socket.inet_aton(group))
    igmp = igmp[:2] + struct.pack("!H", checksum(igmp)) + igmp[4:]

    iph = struct.pack("!BBHHHBBH4s4s", 0x45, 0xc0, 20 + len(igmp), 0, 0, 1, 2,
                      0, socket.inet_aton("192.0.2.100"),
                      socket.inet_aton(group))
    iph = iph[:10] + struct.pack("!H", checksum(iph)) + iph[12:]

    dmac = bytes([0x01, 0x00, 0x5e]) + socket.inet_aton(group)[1:]
    smac = bytes.fromhex("0011223344ff")
    frame = dmac + smac + struct.pack("!H", ETH_P_IP) + iph + igmp
    return frame + b"\0" * (60 - len(frame))


def test_bridge_snooping() -> None:
    """An entry created by IGMP snooping is not a result of a request, and
    the notification carries port ID of zero."""
    with NetNS() as ns:
        env = Env(ns)

        ip("link add br0 up type bridge", ns=ns)
        ip("link add v0 up type veth peer name v1", ns=ns)
        ip("link set dev v0 master br0", ns=ns)
        ip("link set dev v1 up", ns=ns)

        group = "239.3.2.1"
        with NetNSEnter(env.ns):
            tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
            tx.bind(("v1", 0))

        portids = []

        def joined():
            nonlocal portids
            tx.send(igmp_report(group))
            portids = [n.portid for n in env.ntfs()
                       if n.type == RTM_NEWMDB and n.group == group]
            return portids != []

        # Keep sending until the group is joined: a frame that arrives
        # while the bridge port is not yet up is dropped. Once the entry
        # exists, repeated reports only refresh it and do not generate
        # notifications.
        ksft_busy_wait(joined, deadline=2)

        ksft_eq(portids, [0], "nlmsg_pid of snooped entry")


def main() -> None:
    """Run all the tests."""
    ksft_run([
        test_bridge,
        test_bridge_host,
        test_bridge_sources,
        test_bridge_exclude,
        test_bridge_flush,
        test_bridge_flush_host,
        test_bridge_timer,
        test_bridge_snooping,
    ])
    ksft_exit()


if __name__ == "__main__":
    main()
