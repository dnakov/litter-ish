#ifndef FS_NET_ROUTE_H
#define FS_NET_ROUTE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <net/if.h>

#define HOST_ROUTE_PROC_FLAG_UP 0x0001
#define HOST_ROUTE_PROC_FLAG_GATEWAY 0x0002
#define HOST_ROUTE_PROC_FLAG_HOST 0x0004

#define HOST_ROUTE_SCOPE_UNIVERSE 0
#define HOST_ROUTE_SCOPE_LINK 253
#define HOST_ROUTE_SCOPE_HOST 254

#define HOST_ROUTE_PROTOCOL_KERNEL 2
#define HOST_ROUTE_PROTOCOL_BOOT 3

struct host_route_entry {
    char ifname[IFNAMSIZ];
    uint32_t ifindex;
    uint32_t destination_be;
    uint32_t gateway_be;
    uint32_t mask_be;
    uint32_t prefsrc_be;
    uint32_t proc_flags;
    uint32_t mtu;
    uint8_t prefix_len;
    uint8_t scope;
    uint8_t protocol;
    bool is_default;
};

struct host_route_table {
    struct host_route_entry *entries;
    size_t count;
};

int host_route_table_collect(struct host_route_table *table);
void host_route_table_free(struct host_route_table *table);

#endif
