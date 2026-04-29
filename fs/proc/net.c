// /proc/net hierarchy. Tools like ifconfig, ss, route, busybox ip, glibc's
// res_init read these; many treat ENOENT as a hard error. We intentionally
// only expose the entries that don't require iterating sockets across all
// guest tasks (those need a snapshot infrastructure we don't have).
//
// Adapted from ish-AOK 918fb41d.

#include <sys/stat.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <net/if.h>
#include <string.h>
#include "fs/proc.h"
#include "kernel/calls.h"

#if defined(__APPLE__)
#include <net/if_dl.h>
#include <net/if_var.h>
#include "fs/net_route.h"
#endif

static int proc_show_route(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n");
#if defined(__APPLE__)
    struct host_route_table routes = {};
    if (host_route_table_collect(&routes) == 0) {
        for (size_t i = 0; i < routes.count; i++) {
            const struct host_route_entry *route = &routes.entries[i];
            proc_printf(buf, "%s\t%08X\t%08X\t%04X\t%d\t%d\t%d\t%08X\t%u\t%d\t%d\n",
                    route->ifname,
                    route->destination_be,
                    route->gateway_be,
                    route->proc_flags,
                    0, 0, 0,
                    route->mask_be,
                    route->mtu,
                    0, 0);
        }
        host_route_table_free(&routes);
    }
#endif
    return 0;
}

static int proc_show_dev(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "Inter-|   Receive                                                |  Transmit\n");
    proc_printf(buf, " face |bytes    packets errs drop fifo frame compressed multicast"
                     "|bytes    packets errs drop fifo colls carrier compressed\n");
    struct ifaddrs *addrs;
    if (getifaddrs(&addrs) != 0)
        return 0;
    for (const struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL)
            continue;
#if defined(__APPLE__)
        if (cursor->ifa_addr->sa_family != AF_LINK)
            continue;
        const struct if_data *stats = (const struct if_data *) cursor->ifa_data;
        if (stats != NULL) {
            proc_printf(buf, "%6s:%8lu %7lu %4lu %4lu %4lu %5lu %10lu %9lu %8lu %7lu %4lu %4lu %4lu %5lu %7lu %10lu\n",
                    cursor->ifa_name,
                    (unsigned long) stats->ifi_ibytes,
                    (unsigned long) stats->ifi_ipackets,
                    (unsigned long) stats->ifi_ierrors,
                    (unsigned long) stats->ifi_iqdrops,
                    0UL, 0UL, 0UL,
                    (unsigned long) stats->ifi_imcasts,
                    (unsigned long) stats->ifi_obytes,
                    (unsigned long) stats->ifi_opackets,
                    (unsigned long) stats->ifi_oerrors,
                    0UL, 0UL,
                    (unsigned long) stats->ifi_collisions,
                    (unsigned long) (stats->ifi_ierrors + stats->ifi_oerrors),
                    0UL);
            continue;
        }
#endif
        // Linux build or no link-level stats: emit a zero-filled row so
        // /proc/net/dev parsers still see the interface.
#if !defined(__APPLE__)
        if (cursor->ifa_addr->sa_family != AF_PACKET && cursor->ifa_addr->sa_family != AF_INET)
            continue;
#endif
        proc_printf(buf, "%6s:%8d %7d %4d %4d %4d %5d %10d %9d %8d %7d %4d %4d %4d %5d %7d %10d\n",
                cursor->ifa_name, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    freeifaddrs(addrs);
    return 0;
}

static int proc_show_if_inet6(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    struct ifaddrs *addrs;
    if (getifaddrs(&addrs) != 0)
        return 0;
    unsigned ifindex = 0;
    for (const struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_INET6)
            continue;
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *) cursor->ifa_addr;
        const uint8_t *a = sin6->sin6_addr.s6_addr;
        proc_printf(buf, "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x %02x 80 10 80       %s\n",
                a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15],
                ifindex++, cursor->ifa_name);
    }
    freeifaddrs(addrs);
    return 0;
}

// /proc/net/{tcp,tcp6,udp,udp6,unix,raw,raw6,arp} expect to be enumerable
// even when there's nothing to show. Empty bodies (or just a header) keep
// guest tools (ss, netstat, busybox arp) happy.
static int proc_show_tcp(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n");
    return 0;
}
static int proc_show_unix(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "Num       RefCount Protocol Flags    Type St Inode Path\n");
    return 0;
}
static int proc_show_arp(struct proc_entry *UNUSED(entry), struct proc_data *buf) {
    proc_printf(buf, "IP address       HW type     Flags       HW address            Mask     Device\n");
    return 0;
}
static int proc_show_empty(struct proc_entry *UNUSED(entry), struct proc_data *UNUSED(buf)) {
    return 0;
}

struct proc_children proc_net_children = PROC_CHILDREN({
    {"arp", .show = proc_show_arp},
    {"dev", .show = proc_show_dev},
    {"if_inet6", .show = proc_show_if_inet6},
    {"raw", .show = proc_show_empty},
    {"raw6", .show = proc_show_empty},
    {"route", .show = proc_show_route},
    {"tcp", .show = proc_show_tcp},
    {"tcp6", .show = proc_show_tcp},
    {"udp", .show = proc_show_tcp},
    {"udp6", .show = proc_show_tcp},
    {"unix", .show = proc_show_unix},
});
