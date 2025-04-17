#!/bin/zsh
# cached-commands.zsh - Pre-configured cached commands

# Check if command-cache.zsh is loaded
if ! typeset -f cached_exec >/dev/null; then
  echo "Warning: command-cache.zsh not loaded, skipping cached-commands.zsh"
  return 1
fi

# Cache duration constants
CACHE_SHORT=300      # 5 minutes
CACHE_MEDIUM=1800    # 30 minutes
CACHE_LONG=3600      # 1 hour
CACHE_VERY_LONG=86400 # 24 hours

# ========== System Info Cached Commands ==========
# Network interface info (rarely changes during a session)
alias ipc='cache $CACHE_MEDIUM ip-info ifconfig'

# Disk usage (cached)
alias dfc='cache $CACHE_MEDIUM df-info df -h'

# System info (rarely changes)
alias sysc='cache $CACHE_VERY_LONG sys-info system_profiler SPHardwareDataType'

# ========== IBM Cloud CLI Cached Commands ==========
# if command -v ibmcloud &>/dev/null; then
#   # List available regions (rarely changes)
#   alias icreg='cache $CACHE_VERY_LONG ibm-regions ibmcloud regions'
  
#   # List resource groups
#   alias icgroups='cache $CACHE_MEDIUM ibm-resource-groups ibmcloud resource groups'
# fi

# ========== Docker/Podman Cached Commands ==========
# Helper for docker/podman image list (this changes frequently but can be cached briefly)
# if command -v docker &>/dev/null; then
#   alias dimagesc='cache $CACHE_SHORT docker-images docker images'
# fi

# if command -v podman &>/dev/null; then
#   alias pimagesc='cache $CACHE_SHORT podman-images podman images'
# fi
