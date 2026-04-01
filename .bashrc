#!/usr/bin/env bash
# ~/.bashrc: executed by bash for non-login shells
# This is the dotfiles .bashrc file
# Recommended: Symlink ~/.bashrc to the repo so changes are instantly live:
#   ln -sf ~/git/dotfiles/.bashrc ~/.bashrc
#
# Legacy alternative (source instead of symlink):
#   [[ -f ~/git/dotfiles/.bashrc ]] && source ~/git/dotfiles/.bashrc

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# ===== Environment Setup =====
# Homebrew setup
[[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

# ===== History Configuration =====
HISTCONTROL=ignoreboth  # Ignore duplicate lines and lines starting with space
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend     # Append to history file, don't overwrite

# ===== Shell Options =====
shopt -s checkwinsize   # Update window size after each command
shopt -s globstar       # "**" matches all files and zero or more directories

# ===== Aliases =====
alias z='zsh -i'
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

# ===== Prompt =====
# Set a simple prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# ===== Additional Configuration =====
# Cargo environment
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

# npm global binaries
export PATH=~/.npm-global/bin:$PATH
