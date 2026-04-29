#include "fs/net_route.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <net/if_var.h>
#endif

struct route_iface_info {
    char ifname[IFNAMSIZ];
    unsigned flags;
    uint32_t mtu;
    uint32_t ifindex;
};

static bool route_name_has_prefix(const char *name, const char *prefix) {
    return strncmp(name, prefix, strlen(prefix)) == 0;
}

static bool route_name_hidden(const char *name) {
    return route_name_has_prefix(name, "awdl") ||
        route_name_has_prefix(name, "llw") ||
        route_name_has_prefix(name, "anpi");
}

static bool route_addr_is_link_local(uint32_t addr_be) {
    uint32_t addr = ntohl(addr_be);
    return (addr & 0xffff0000u) == 0xa9fe0000u;
}

static uint8_t route_prefixlen(uint32_t mask_be) {
    uint32_t mask = ntohl(mask_be);
    uint8_t prefix = 0;
    while ((mask & 0x80000000u) != 0) {
        prefix++;
        mask <<= 1;
    }
    return prefix;
}

static struct route_iface_info *route_iface_find(struct route_iface_info *infos, size_t count,
        const char *ifname) {
    for (size_t i = 0; i < count; i++) {
        if (strncmp(infos[i].ifname, ifname, sizeof(infos[i].ifname)) == 0)
            return &infos[i];
    }
    return NULL;
}

static int route_iface_upsert(struct route_iface_info **infos, size_t *count, const char *ifname,
        unsigned flags, uint32_t mtu, uint32_t ifindex) {
    struct route_iface_info *info = route_iface_find(*infos, *count, ifname);
    if (info != NULL) {
        info->flags = flags;
        if (mtu != 0)
            info->mtu = mtu;
        if (ifindex != 0)
            info->ifindex = ifindex;
        return 0;
    }
    struct route_iface_info *new_infos = realloc(*infos, sizeof(**infos) * (*count + 1));
    if (new_infos == NULL)
        return -1;
    *infos = new_infos;
    info = &new_infos[*count];
    memset(info, 0, sizeof(*info));
    strncpy(info->ifname, ifname, sizeof(info->ifname) - 1);
    info->flags = flags;
    info->mtu = mtu;
    info->ifindex = ifindex;
    (*count)++;
    return 0;
}

static int host_route_table_append(struct host_route_table *table, const struct host_route_entry *entry) {
    for (size_t i = 0; i < table->count; i++) {
        struct host_route_entry *existing = &table->entries[i];
        if (strncmp(existing->ifname, entry->ifname, sizeof(existing->ifname)) == 0 &&
                existing->destination_be == entry->destination_be &&
                existing->mask_be == entry->mask_be &&
                existing->gateway_be == entry->gateway_be &&
                existing->is_default == entry->is_default) {
            return 0;
        }
    }
    struct host_route_entry *new_entries = realloc(table->entries, sizeof(*new_entries) * (table->count + 1));
    if (new_entries == NULL)
        return -1;
    table->entries = new_entries;
    table->entries[table->count++] = *entry;
    return 0;
}

static int route_default_score(const char *ifname, unsigned flags, uint32_t addr_be) {
    if ((flags & IFF_UP) == 0 || (flags & IFF_RUNNING) == 0)
        return -1;
    if ((flags & IFF_LOOPBACK) != 0)
        return -1;
    if (route_name_hidden(ifname))
        return -1;
    if (route_addr_is_link_local(addr_be))
        return -1;

    int score = 200;
    if (route_name_has_prefix(ifname, "en") ||
            route_name_has_prefix(ifname, "bridge") ||
            route_name_has_prefix(ifname, "pdp_ip"))
        score = 400;
    else if (route_name_has_prefix(ifname, "ap"))
        score = 350;
    else if (route_name_has_prefix(ifname, "utun"))
        score = 300;
    if (flags & IFF_POINTOPOINT)
        score -= 25;
    return score;
}

int host_route_table_collect(struct host_route_table *table) {
    memset(table, 0, sizeof(*table));

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0)
        return -1;

    struct route_iface_info *ifinfos = NULL;
    size_t ifinfos_count = 0;
    for (const struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_name == NULL || cursor->ifa_addr == NULL)
            continue;
#if defined(__APPLE__)
        if (cursor->ifa_addr->sa_family == AF_LINK) {
            uint32_t mtu = 0;
            if (cursor->ifa_data != NULL) {
                const struct if_data *stats = (const struct if_data *) cursor->ifa_data;
                mtu = stats->ifi_mtu;
            }
            if (route_iface_upsert(&ifinfos, &ifinfos_count, cursor->ifa_name,
                    cursor->ifa_flags, mtu, if_nametoindex(cursor->ifa_name)) < 0) {
                free(ifinfos);
                freeifaddrs(addrs);
                host_route_table_free(table);
                return -1;
            }
        }
#endif
    }

    struct host_route_entry default_route = {};
    int default_score = -1;
    for (const struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
        if (cursor->ifa_name == NULL || cursor->ifa_addr == NULL || cursor->ifa_netmask == NULL)
            continue;
        if (cursor->ifa_addr->sa_family != AF_INET)
            continue;

        struct route_iface_info *ifinfo = route_iface_find(ifinfos, ifinfos_count, cursor->ifa_name);
        unsigned flags = ifinfo != NULL ? ifinfo->flags : cursor->ifa_flags;
        uint32_t mtu = ifinfo != NULL ? ifinfo->mtu : 0;
        uint32_t ifindex = ifinfo != NULL && ifinfo->ifindex != 0 ? ifinfo->ifindex : if_nametoindex(cursor->ifa_name);

        struct sockaddr_in *addr_in = (struct sockaddr_in *) cursor->ifa_addr;
        struct sockaddr_in *mask_in = (struct sockaddr_in *) cursor->ifa_netmask;
        uint32_t addr_be = addr_in->sin_addr.s_addr;
        uint32_t mask_be = mask_in->sin_addr.s_addr;
        if (mask_be == 0 && !(flags & IFF_LOOPBACK))
            continue;

        if (!route_name_hidden(cursor->ifa_name) && !route_addr_is_link_local(addr_be)) {
            struct host_route_entry route = {};
            strncpy(route.ifname, cursor->ifa_name, sizeof(route.ifname) - 1);
            route.ifindex = ifindex;
            route.destination_be = addr_be & mask_be;
            route.gateway_be = 0;
            route.mask_be = mask_be;
            route.prefsrc_be = addr_be;
            route.mtu = mtu != 0 ? mtu : 1500;
            route.prefix_len = route_prefixlen(mask_be);
            route.scope = (flags & IFF_LOOPBACK) ? HOST_ROUTE_SCOPE_HOST : HOST_ROUTE_SCOPE_LINK;
            route.protocol = HOST_ROUTE_PROTOCOL_KERNEL;
            route.proc_flags = HOST_ROUTE_PROC_FLAG_UP;
            if (mask_be == htonl(0xffffffffu))
                route.proc_flags |= HOST_ROUTE_PROC_FLAG_HOST;
            if (host_route_table_append(table, &route) < 0) {
                free(ifinfos);
                freeifaddrs(addrs);
                host_route_table_free(table);
                return -1;
            }
        }

        int score = route_default_score(cursor->ifa_name, flags, addr_be);
        if (score > default_score ||
                (score == default_score && default_route.ifindex != 0 && ifindex < default_route.ifindex)) {
            default_score = score;
            memset(&default_route, 0, sizeof(default_route));
            strncpy(default_route.ifname, cursor->ifa_name, sizeof(default_route.ifname) - 1);
            default_route.ifindex = ifindex;
            default_route.destination_be = 0;
            default_route.gateway_be = 0;
            default_route.mask_be = 0;
            default_route.prefsrc_be = addr_be;
            default_route.mtu = mtu != 0 ? mtu : 1500;
            default_route.prefix_len = 0;
            default_route.scope = HOST_ROUTE_SCOPE_LINK;
            default_route.protocol = HOST_ROUTE_PROTOCOL_BOOT;
            default_route.proc_flags = HOST_ROUTE_PROC_FLAG_UP;
            if ((flags & IFF_POINTOPOINT) == 0)
                default_route.proc_flags |= HOST_ROUTE_PROC_FLAG_GATEWAY;
            default_route.is_default = true;
        }
    }

    if (default_score >= 0) {
        if (host_route_table_append(table, &default_route) < 0) {
            free(ifinfos);
            freeifaddrs(addrs);
            host_route_table_free(table);
            return -1;
        }
    }

    free(ifinfos);
    freeifaddrs(addrs);
    return 0;
}

void host_route_table_free(struct host_route_table *table) {
    free(table->entries);
    table->entries = NULL;
    table->count = 0;
}
