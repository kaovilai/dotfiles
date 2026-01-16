#!/usr/bin/env zsh
# zsh_profiler.zsh - Tool to profile zsh startup performance

# Enable zsh profiling
zmodload zsh/datetime
zmodload zsh/mathfunc
zmodload zsh/zutil

# Store the starting time
_zsh_profile_start=$EPOCHREALTIME

# Initialize the performance report
typeset -A _zsh_profile_report
typeset -a _zsh_profile_sections

_PROFILE_START_TIMES=()
_PROFILE_NAMES=()
_PROFILE_INDENT_LEVEL=0
_PROFILE_INDENT_STR=""

# Colors for output
PROFILE_RED=$'\e[31m'
PROFILE_YELLOW=$'\e[33m'
PROFILE_GREEN=$'\e[32m'
PROFILE_BLUE=$'\e[34m'
PROFILE_MAGENTA=$'\e[35m'
PROFILE_CYAN=$'\e[36m'
PROFILE_RESET=$'\e[0m'
PROFILE_BOLD=$'\e[1m'
PROFILE_DIM=$'\e[2m'

# Function to start profiling a section
_profile_start() {
  local name=$1
  local indent_str=""
  
  # Create indentation
  for ((i = 0; i < _PROFILE_INDENT_LEVEL; i++)); do
    indent_str="${indent_str}  "
  done
  
  # Save the section name, start time and indentation
  _PROFILE_START_TIMES+=($EPOCHREALTIME)
  _PROFILE_NAMES+=("$name")
  _PROFILE_INDENT_STR=$indent_str
  
  # Increase indentation for nested sections
  ((_PROFILE_INDENT_LEVEL++))
}

# Function to end profiling a section
_profile_end() {
  local end_time=$EPOCHREALTIME
  
  # Decrease indentation level
  ((_PROFILE_INDENT_LEVEL--))
  
  # Pop the last section
  local start_time=${_PROFILE_START_TIMES[-1]}
  local name=${_PROFILE_NAMES[-1]}
  local indent_str=$_PROFILE_INDENT_STR
  
  # Remove the last element
  _PROFILE_START_TIMES=(${_PROFILE_START_TIMES[1,-2]})
  _PROFILE_NAMES=(${_PROFILE_NAMES[1,-2]})
  
  # Calculate duration in milliseconds
  local duration=$(( (end_time - start_time) * 1000 ))
  
  # Store the result in our report
  _zsh_profile_report[$name]=$duration
  _zsh_profile_sections+=("$name")
  
  # Output immediately if debug is enabled
  if [[ -n "$ZSH_PROFILE_DEBUG" ]]; then
    # Color-code based on duration
    local color=$PROFILE_GREEN
    local duration_formatted
    
    if (( duration >= 100 )); then
      color=$PROFILE_RED
      duration_formatted="${PROFILE_BOLD}${duration}ms${PROFILE_RESET}"
    elif (( duration >= 20 )); then
      color=$PROFILE_YELLOW
      duration_formatted="${duration}ms"
    else
      duration_formatted="${PROFILE_DIM}${duration}ms${PROFILE_RESET}"
    fi
    
    echo "${indent_str}${color}${name}${PROFILE_RESET}: ${duration_formatted}"
  fi
}

# Profile function to wrap code blocks
profile() {
  local name=$1
  local cmd=$2
  
  _profile_start "$name"
  eval "$cmd"
  _profile_end
}

# Function to profile sourcing a file
profile_source() {
  local file=$1
  _profile_start "source ${file:t}"
  source "$file"
  _profile_end
}

# Function to detect network operations
profile_with_network_check() {
  local name=$1
  local cmd=$2
  
  # Capture network activity before operation
  local net_before
  if command -v nettop &>/dev/null; then
    net_before=$(nettop -P -L 1 -x -t wifi -t wired | grep -v nettop)
  fi
  
  _profile_start "$name"
  eval "$cmd"
  
  # Check network activity after operation
  local net_after
  if command -v nettop &>/dev/null; then
    net_after=$(nettop -P -L 1 -x -t wifi -t wired | grep -v nettop)
  fi
  
  # Add network indicator if activity detected
  if [[ "$net_before" != "$net_after" ]]; then
    _PROFILE_NAMES[-1]="${_PROFILE_NAMES[-1]} ${PROFILE_BLUE}[NET]${PROFILE_RESET}"
  fi
  
  _profile_end
}

# Function to print a sorted performance report
_zsh_profile_print_report() {
  local total_time=$(( (EPOCHREALTIME - _zsh_profile_start) * 1000 ))
  local -a sorted_sections
  
  # Create an array for sorting
  for section in ${_zsh_profile_sections}; do
    local time=${_zsh_profile_report[$section]}
    # Add padding for sorting
    local padded_time=$(printf "%08d" $(echo "$time * 1000" | bc | cut -d. -f1))
    sorted_sections+=("$padded_time:$section:$time")
  done
  
  # Sort sections by time (descending)
  sorted_sections=(${(On)sorted_sections})
  
  echo "\n${PROFILE_BOLD}ZSH STARTUP PROFILE${PROFILE_RESET} (Total: ${total_time}ms)\n"
  echo "${PROFILE_BOLD}TOP 10 SLOWEST OPERATIONS:${PROFILE_RESET}"
  
  # Print top 10 slowest items
  local count=0
  for item in ${sorted_sections}; do
    local section=$(echo $item | cut -d: -f2)
    local time=$(echo $item | cut -d: -f3)
    
    # Format time with color based on duration
    local color=$PROFILE_GREEN
    local time_formatted
    
    if (( time >= 100 )); then
      color=$PROFILE_RED
      time_formatted="${PROFILE_BOLD}${time}ms${PROFILE_RESET}"
    elif (( time >= 20 )); then
      color=$PROFILE_YELLOW
      time_formatted="${time}ms"
    else
      time_formatted="${PROFILE_DIM}${time}ms${PROFILE_RESET}"
    fi
    
    # Calculate percentage 
    local percent=$(( time * 100 / total_time ))
    
    echo "${color}${section}${PROFILE_RESET}: ${time_formatted} (${percent}%)"
    
    (( count++ ))
    [[ $count -eq 10 ]] && break
  done
  
  echo "\n${PROFILE_BOLD}NETWORK OPERATIONS:${PROFILE_RESET}"
  for item in ${sorted_sections}; do
    local section=$(echo $item | cut -d: -f2)
    local time=$(echo $item | cut -d: -f3)
    
    # Only show network operations
    if [[ "$section" == *"[NET]"* ]]; then
      echo "${PROFILE_BLUE}${section}${PROFILE_RESET}: ${time}ms"
    fi
  done
  
  echo "\n${PROFILE_BOLD}COMPLETION OPERATIONS:${PROFILE_RESET}"
  for item in ${sorted_sections}; do
    local section=$(echo $item | cut -d: -f2)
    local time=$(echo $item | cut -d: -f3)
    
    # Only show completion-related operations
    if [[ "$section" == *"complet"* || "$section" == *"compin"* ]]; then
      echo "${PROFILE_MAGENTA}${section}${PROFILE_RESET}: ${time}ms"
    fi
  done
}

# Register hook to print report when shell is ready
zsh_profile_hook() {
  # Wait a bit to ensure all initialization is complete
  (sleep 0.1 && _zsh_profile_print_report) &!
}

# Enable debug output if requested
# export ZSH_PROFILE_DEBUG=1

# Add the hook to precmd
autoload -Uz add-zsh-hook
add-zsh-hook precmd zsh_profile_hook
