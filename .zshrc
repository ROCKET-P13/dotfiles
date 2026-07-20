# Homebrew (Apple Silicon)
eval "$(/opt/homebrew/bin/brew shellenv)"

# oh-my-zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"

plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# Dotfiles are tracked by a bare git repo: gitdir at ~/.dotfiles, work-tree at $HOME.
# This alias lets you manage them in place, e.g. `dotfiles add ~/.zshrc && dotfiles commit -m ... && dotfiles push`.
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
