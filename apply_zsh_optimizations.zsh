#!/usr/bin/env zsh
# apply_zsh_optimizations.zsh - Script to apply ZSH optimizations

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

backup_existing() {
  print_step "Creating backup of existing .zshrc..."
  
  # Create a backup with timestamp
  local timestamp=$(date +"%Y%m%d_%H%M%S")
  cp ~/.zshrc ~/.zshrc.backup.$timestamp
  
  print_success "Backup created at ~/.zshrc.backup.$timestamp"
}

profile_current_config() {
  print_header "PROFILING CURRENT ZSH CONFIGURATION"
  
  print_step "Running shell with profiling enabled..."
  echo "This will open a new zsh instance with profiling. Exit it when done."
  
  # Run a new shell with profiling
  zsh -c "source ~/git/dotfiles/profiled_zshrc; exec zsh"
  
  print_success "Profiling complete"
}

test_optimized_config() {
  print_header "TESTING OPTIMIZED CONFIGURATION"
  
  print_step "Starting shell with optimized configuration..."
  echo "This will open a new zsh instance with optimizations. Exit it when done."
  
  # Run a new shell with optimized config
  zsh -c "source ~/git/dotfiles/optimized_zshrc; exec zsh"
  
  print_success "Test complete"
}

apply_optimizations() {
  print_header "APPLYING ZSH OPTIMIZATIONS"
  
  # Backup existing configuration
  backup_existing
  
  print_step "Installing optimized .zshrc..."
  cp ~/git/dotfiles/optimized_zshrc ~/.zshrc
  
  print_success "Optimizations applied successfully!"
  print_success "Your original .zshrc has been backed up"
  print_success "New optimized .zshrc is now active"
  
  echo ""
  echo "To revert back to your original configuration:"
  echo "cp ~/.zshrc.backup.* ~/.zshrc"
  echo ""
}

# Main menu
print_header "ZSH STARTUP OPTIMIZATION TOOL"
echo ""
echo "This script will help you optimize your ZSH startup time."
echo ""
echo "Choose an option:"
echo "1. Profile your current ZSH configuration"
echo "2. Test optimized configuration (without applying)"
echo "3. Apply optimizations permanently"
echo "4. Exit"
echo ""

read -k 1 "choice?Enter option (1-4): "
echo ""

case $choice in
  1)
    profile_current_config
    ;;
  2)
    test_optimized_config
    ;;
  3)
    apply_optimizations
    ;;
  4)
    print_step "Exiting..."
    exit 0
    ;;
  *)
    print_warning "Invalid option"
    ;;
esac

echo ""
print_header "OPTIMIZATION COMPLETED"
echo "For more information, see ~/git/dotfiles/zsh_optimization_readme.md"
