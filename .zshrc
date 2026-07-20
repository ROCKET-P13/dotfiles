# Dotfiles are tracked by a bare git repo: gitdir at ~/.dotfiles, work-tree at $HOME.
# This alias lets you manage them in place, e.g. `dotfiles add ~/.zshrc && dotfiles commit -m ... && dotfiles push`.
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
