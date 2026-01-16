#!/usr/bin/env zsh
# zsh_speedup.zsh - Master script for ZSH performance optimization

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

# Measure current startup time
measure_current_time() {
  print_step "Measuring current zsh startup time..."
  local current_time=$(TIMEFMT='%mE'; time zsh -i -c exit 2>&1)
  echo "Current startup time: $current_time"
  
  # Store for later comparison
  echo "$current_time" > /tmp/zsh_startup_before.txt
}

# Apply selected optimization level
apply_optimization() {
  local level=$1
  local target=~/.zshrc
  local backup=~/.zshrc.backup.$(date +"%Y%m%d_%H%M%S")
  
  print_step "Creating backup at $backup..."
  cp "$target" "$backup"
  
  case "$level" in
    1)
      print_step "Applying basic optimization (lazy completions)..."
      cp ~/git/dotfiles/optimized_zshrc "$target"
      ;;
    2)
      print_step "Applying advanced optimization..."
      cp ~/git/dotfiles/supercharged_zshrc "$target"
      ;;
    *)
      print_warning "Invalid optimization level"
      return 1
      ;;
  esac
  
  print_success "Applied optimization level $level"
  print_success "Backup created at $backup"
}

# Compare before/after
show_speedup() {
  print_step "Measuring optimized zsh startup time..."
  local new_time=$(TIMEFMT='%mE'; time zsh -i -c exit 2>&1)
  echo "New startup time: $new_time"
  
  if [[ -f /tmp/zsh_startup_before.txt ]]; then
    local old_time=$(cat /tmp/zsh_startup_before.txt)
    
    # Convert times to milliseconds for comparison (assuming format like "123.45ms")
    local old_ms=$(echo $old_time | sed 's/ms//')
    local new_ms=$(echo $new_time | sed 's/ms//')
    
    if (( $(echo "$new_ms < $old_ms" | bc -l) )); then
      local speedup=$(echo "scale=1; $old_ms / $new_ms" | bc -l)
      print_success "Startup is now ${speedup}x faster!"
    else
      print_warning "No speed improvement detected. Check for errors."
    fi
  fi
}

# Compile zsh files
compile_zsh_files() {
  print_step "Compiling zsh files for faster loading..."
  
  # Compile all zsh files
  for file in ~/git/dotfiles/zsh/*.zsh; do
    zcompile "$file"
    print_success "Compiled $(basename $file)"
  done
  
  # Compile .zshrc
  zcompile ~/.zshrc
  print_success "Compiled .zshrc"
  
  # Compile zcompdump
  if [[ -f ~/.zcompdump ]]; then
    zcompile ~/.zcompdump
    print_success "Compiled .zcompdump"
  fi
}

# Run the profiler
run_profiler() {
  print_step "Running zsh profiler to analyze startup performance..."
  zsh -c "source ~/git/dotfiles/profiled_zshrc; exec zsh"
}

show_main_menu() {
  clear
  print_header "ZSH STARTUP SPEEDUP"
  echo ""
  echo "This script will help you optimize your ZSH startup time."
  echo ""
  echo "Choose an option:"
  echo "1. Measure Current Startup Time"
  echo "2. Run Detailed Profiler"
  echo "3. Apply Basic Optimization (Safe)"
  echo "4. Apply Supercharged Optimization (Maximum Performance)"
  echo "5. Apply Advanced Tweaks"
  echo "6. Compile ZSH Files"
  echo "7. Show Documentation"
  echo "8. Revert to Backup"
  echo "9. Exit"
  echo ""
  
  read -k 1 "choice?Enter option (1-9): "
  echo ""
  
  case $choice in
    1)
      measure_current_time
      ;;
    2)
      run_profiler
      ;;
    3)
      measure_current_time
      apply_optimization 1
      show_speedup
      ;;
    4)
      measure_current_time
      apply_optimization 2
      compile_zsh_files
      show_speedup
      ;;
    5)
      ./apply_advanced_optimizations.zsh
      ;;
    6)
      compile_zsh_files
      ;;
    7)
      if command -v less >/dev/null 2>&1; then
        less ~/git/dotfiles/zsh_speedup_summary.md
      else
        cat ~/git/dotfiles/zsh_speedup_summary.md | more
      fi
      ;;
    8)
      local backups=(~/.zshrc.backup.*)
      if (( ${#backups[@]} > 0 )); then
        echo "Available backups:"
        for i in "${!backups[@]}"; do
          echo "$((i+1)). ${backups[$i]}"
        done
        
        read "backup_choice?Enter backup number to restore: "
        if [[ -n "$backup_choice" && "$backup_choice" -le "${#backups[@]}" ]]; then
          local selected=${backups[$((backup_choice-1))]}
          cp "$selected" ~/.zshrc
          print_success "Restored backup from $selected"
        else
          print_warning "Invalid selection"
        fi
      else
        print_warning "No backups found"
      fi
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
  read -k 1 "?Press any key to return to menu..."
  show_main_menu
}

# Start the script
show_main_menu
