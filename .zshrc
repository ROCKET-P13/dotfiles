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

# Dotfiles are tracked by a normal git repo rooted at $HOME (gitdir ~/.git).
# Manage them in place with plain git from $HOME, e.g. `git add -f ~/.zshrc && git commit -m ... && git push`.
# ~/.gitignore ignores everything (*) so only tracked files are visible; use `git add -f` for new files.
