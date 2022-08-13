#!/bin/bash

# create directory for ipfs if does not exist
mkdir -p ~/.ipfs

# start container and save its id
container=$(podman run --rm -d --name ipfs -v ~/.ipfs:/data/ipfs -e LIBP2P_TCP_REUSEPORT=false --pull=always docker.io/ipfs/go-ipfs)

# get slirp4netns id of containers
netkey=$(podman inspect $container|jq -r .[0].NetworkSettings.SandboxKey)

# get pid of slirp4netns
netpid=$(pgrep -f $netkey)

# get cgroup of slirp4netns process
netcgroup=$(< /proc/$netpid/cgroup tr ":" "\n"|tail -n 1|cut -c 2-)
#level of cgroup
netcgrouplevel=$(($(echo $netcgroup | tr -cd '/'|wc -c)+1))

# Add chains
nft 'add chain ip filter ipfs_limit_in {type filter hook input priority 0; }'
nft 'add chain ip filter ipfs_limit_out {type filter hook output priority 0; }'

# Clear chains
nft 'flush chain ip filter ipfs_limit_in'
nft 'flush chain ip filter ipfs_limit_out'

#TCP
# Add set of allowed TCP peers
nft 'add set filter ipfs_allow_tcp { type ipv4_addr; size 50; timeout 5m;}'

# Whitelist ip on connection attempt in any direction
nft "add rule filter ipfs_limit_in \
 ip protocol tcp \
 cgroupv2 level $netcgrouplevel \"$netcgroup\" \
 ct state {new, established} \
 update @ipfs_allow_tcp {ip daddr timeout 5m}"
nft "add rule filter ipfs_limit_out \
 ip protocol tcp \
 cgroupv2 level $netcgrouplevel \"$netcgroup\" \
 ct state {new, established} \
 update @ipfs_allow_tcp {ip daddr timeout 5m}"

# Drop connections if not in whitelist
nft "add rule filter ipfs_limit_in \
  ip protocol tcp \
  cgroupv2 level $netcgrouplevel \"$netcgroup\" \
  ip saddr != @ipfs_allow_tcp \
  drop"
nft "add rule filter ipfs_limit_in \
  ip protocol tcp \
  cgroupv2 level $netcgrouplevel \"$netcgroup\" \
  ip saddr != @ipfs_allow_tcp \
  reject with icmp type admin-prohibited"


#UDP
# Add set of allowed UDP peers
nft 'add set filter ipfs_allow_udp { type ipv4_addr; size 50; timeout 5m;}'

# Add peers to whitelist on packet sent in any direction
nft "add rule filter ipfs_limit_in \
 ip protocol udp \
 socket cgroupv2 level $netcgrouplevel \"$netcgroup\" \
 update @ipfs_allow_udp {ip daddr timeout 5m}"
nft "add rule filter ipfs_limit_out \
 ip protocol udp \
 socket cgroupv2 level $netcgrouplevel \"$netcgroup\" \
 update @ipfs_allow_udp {ip daddr timeout 5m}"

# If packet destination not in whitelist drop
nft 'add rule filter ipfs_limit_in  ip protocol udp ip saddr != @ipfs_allow_udp drop'
nft 'add rule filter ipfs_limit_out ip protocol udp ip daddr != @ipfs_allow_udp drop'



