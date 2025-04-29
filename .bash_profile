#!/usr/bin/env bash
# ~/.bash_profile: executed by bash for login shells
# This is the dotfiles .bash_profile file
# Your ~/.bash_profile should point here with:
# [[ -f ~/git/dotfiles/.bash_profile ]] && source ~/git/dotfiles/.bash_profile

# ===== Path Configuration =====
# Set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ] ; then
    PATH="$HOME/bin:$PATH"
fi

if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

# ===== Environment Variables =====
export EDITOR="code -w"
export VISUAL=vim
export PAGER=less

# ===== Load .bashrc =====
# Get the aliases and functions from .bashrc
if [ -f ~/git/dotfiles/.bashrc ]; then
    source ~/git/dotfiles/.bashrc
fi

# ===== Additional Login Configuration =====
# Add any login-specific configurations here
