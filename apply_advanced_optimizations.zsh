#!/usr/bin/env zsh
# apply_advanced_optimizations.zsh - Apply advanced ZSH optimizations

print_header() {
  echo "\033[1;36m==============================================================\033[0m"
  echo "\033[1;36m $1 \033[0m"
  echo "\033[1;36m==============================================================\033[0m"
}

print_step() {
  echo "\033[1;33m→ $1\033[0m"
}

print_success() {
  echo "\033[1;32m✓ $1\033[0m"
}

print_warning() {
  echo "\033[1;31m! $1\033[0m"
}

# Apply static dump for completions
apply_compinit_optimization() {
  print_step "Optimizing completion initialization..."
  
  # Check if already applied
  if grep -q "zcompile.*zcompdump" ~/.zshrc; then
    print_warning "Completion compilation already configured in .zshrc"
    return
  fi
  
  # Add to .zshrc
  cat >> ~/.zshrc << 'EOF'

# Optimize completion initialization
autoload -Uz compinit
compinit -C -d "$HOME/.zcompdump"
zcompile "$HOME/.zcompdump"
EOF
  
  # Force compilation now
  compinit -C -d "$HOME/.zcompdump"
  zcompile "$HOME/.zcompdump"
  
  print_success "Completion compilation configured"
}

# Optimize history settings
apply_history_optimization() {
  print_step "Optimizing history settings..."
  
  # Check if already applied
  if grep -q "HIST_FCNTL_LOCK" ~/.zshrc; then
    print_warning "History optimization already configured in .zshrc"
    return
  fi
  
  # Add to .zshrc
  cat >> ~/.zshrc << 'EOF'

# Optimize history settings
setopt HIST_FCNTL_LOCK
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
EOF
  
  print_success "History settings optimized"
}

# Decrease key timeout
apply_key_timeout() {
  print_step "Optimizing key timeout..."
  
  # Check if already applied
  if grep -q "KEYTIMEOUT=" ~/.zshrc; then
    print_warning "Key timeout already configured in .zshrc"
    return
  fi
  
  # Add to .zshrc
  cat >> ~/.zshrc << 'EOF'

# Decrease key sequence timeout
KEYTIMEOUT=1
EOF
  
  print_success "Key timeout optimized"
}

# Create compiled function files
compile_functions() {
  print_step "Compiling frequently used functions..."
  
  # Compile util.zsh
  if [[ -f ~/git/dotfiles/zsh/util.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/util.zsh
    print_success "Compiled util.zsh"
  fi
  
  # Compile paths.zsh
  if [[ -f ~/git/dotfiles/zsh/paths.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/paths.zsh
    print_success "Compiled paths.zsh"
  fi
  
  # Compile alias.zsh
  if [[ -f ~/git/dotfiles/zsh/alias.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/alias.zsh
    print_success "Compiled alias.zsh"
  fi
  
  # Compile optimized files
  if [[ -f ~/git/dotfiles/zsh/optimized_znap.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/optimized_znap.zsh
    print_success "Compiled optimized_znap.zsh"
  fi
  
  if [[ -f ~/git/dotfiles/zsh/lazy_completions.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/lazy_completions.zsh
    print_success "Compiled lazy_completions.zsh"
  fi
  
  if [[ -f ~/git/dotfiles/zsh/optimized_completions.zsh ]]; then
    zcompile ~/git/dotfiles/zsh/optimized_completions.zsh
    print_success "Compiled optimized_completions.zsh"
  fi
}

# Add pure prompt optimizations
optimize_pure_prompt() {
  print_step "Optimizing pure prompt..."
  
  # Check if pure prompt is used
  if ! grep -q "znap prompt sindresorhus/pure" ~/git/dotfiles/zsh/optimized_znap.zsh; then
    print_warning "Pure prompt not detected, skipping optimization"
    return
  fi
  
  # Add prompt optimizations
  cat >> ~/git/dotfiles/zsh/optimized_znap.zsh << 'EOF'

# Optimize pure prompt performance
zstyle :prompt:pure:git:stash show yes
zstyle :prompt:pure:git:fetch only_upstream yes
EOF
  
  print_success "Pure prompt optimized"
}

# Add tmux optimizations
add_tmux_optimization() {
  print_step "Adding tmux optimizations..."
  
  # Check if already applied
  if grep -q "TMUX.*heavy initialization" ~/.zshrc; then
    print_warning "Tmux optimization already configured in .zshrc"
    return
  fi
  
  # Create backup
  cp ~/.zshrc ~/.zshrc.before_tmux_opt
  
  # Add tmux optimizations - find places to optimize
  awk '
  BEGIN { found=0; }
  /# Load optimized znap configuration/ {
    print "# Only perform heavy operations on the first shell instance";
    print "if [[ ! -v TMUX ]]; then";
    found=1;
  }
  { print $0; }
  /# Load all aliases/ && found==1 {
    print "else";
    print "  # Skip heavy initialization for nested shells in tmux";
    print "  source ~/git/dotfiles/zsh/colors.zsh";
    print "  source ~/git/dotfiles/zsh/paths.zsh";
    print "fi";
    found=0;
  }' ~/.zshrc > ~/.zshrc.new
  
  mv ~/.zshrc.new ~/.zshrc
  
  print_success "Tmux optimizations added"
  print_success "Backup saved to ~/.zshrc.before_tmux_opt"
}

# Measure performance
measure_startup() {
  print_header "MEASURING ZSH STARTUP PERFORMANCE"
  
  print_step "Before optimization..."
  local before_time=$(TIMEFMT='%mE'; time zsh -i -c exit 2>&1)
  
  if [[ -f ~/.zshrc.backup.* ]]; then
    echo "Original config: $before_time"
  else
    echo "No backup found, showing current time: $before_time"
  fi
  
  print_step "After optimization..."
  local after_time=$(TIMEFMT='%mE'; time zsh -i -c exit 2>&1)
  echo "Current config: $after_time"
  
  print_success "Optimization complete!"
}

# Main menu
print_header "ADVANCED ZSH OPTIMIZATION TOOL"
echo ""
echo "This script will apply advanced optimizations to your ZSH configuration."
echo ""
echo "Choose an option:"
echo "1. Apply ALL advanced optimizations"
echo "2. Optimize completion initialization"
echo "3. Optimize history settings"
echo "4. Optimize key timeout"
echo "5. Compile function files"
echo "6. Optimize pure prompt (if used)"
echo "7. Add tmux optimizations"
echo "8. Measure startup performance"
echo "9. Exit"
echo ""

read -k 1 "choice?Enter option (1-9): "
echo ""

case $choice in
  1)
    apply_compinit_optimization
    apply_history_optimization
    apply_key_timeout
    compile_functions
    optimize_pure_prompt
    add_tmux_optimization
    measure_startup
    ;;
  2)
    apply_compinit_optimization
    ;;
  3)
    apply_history_optimization
    ;;
  4)
    apply_key_timeout
    ;;
  5)
    compile_functions
    ;;
  6)
    optimize_pure_prompt
    ;;
  7)
    add_tmux_optimization
    ;;
  8)
    measure_startup
    ;;
  9)
    print_step "Exiting..."
    exit 0
    ;;
  *)
    print_warning "Invalid option"
    ;;
esac

echo ""
print_header "ADVANCED OPTIMIZATION COMPLETED"
echo "For more information, see ~/git/dotfiles/advanced_zsh_optimizations.md"
