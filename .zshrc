# Homebrew (Apple Silicon)
eval "$(/opt/homebrew/bin/brew shellenv)"

# oh-my-zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# Powerlevel10k prompt config
[[ ! -r ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Dotfiles are tracked by a bare git repo: gitdir at ~/.dotfiles, work-tree at $HOME.
# This alias lets you manage them in place, e.g. `dotfiles add ~/.zshrc && dotfiles commit -m ... && dotfiles push`.
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
