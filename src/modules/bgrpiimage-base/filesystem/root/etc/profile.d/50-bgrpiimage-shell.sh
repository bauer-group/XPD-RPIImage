# bgRPIImage - interactive shell conveniences.
#
# Debian ships ll/la/l COMMENTED OUT in /etc/skel/.bashrc (bash package,
# lines 91-93), and pi-gen's only skel patch touches force_color_prompt, PS1
# and the grep aliases - never those three. Every account on a stock
# Raspberry Pi OS Lite image therefore comes up without `ll`, and root is
# worse off still: /root/.bashrc has no active line at all.
#
# This file is sourced by /etc/profile's run-parts loop, i.e. for LOGIN
# shells - ssh, the serial console, `sudo -i`, `su -`, `sudo su -`. Debian's
# /etc/bash.bashrc does NOT source /etc/profile.d, so bgrpiimage-base also
# appends a hook there to cover non-login interactive shells (`sudo su`,
# `sudo -s`, a bare `bash`, tmux panes).
#
# Aliases are an interactive convenience ONLY. `sudo <cmd>` execs the binary
# directly and bash never expands aliases in a non-interactive shell, so
# `sudo ll` cannot be made to work - use `sudo ls -la`.
#
# Deliberately POSIX-sh clean: dash sources this file for `sh` login shells.
# Override any of these in your own ~/.bashrc or ~/.bash_aliases, which are
# read after this file and win.

# Nothing below is meaningful to a non-interactive shell (e.g. `bash -lc`).
[ -n "${PS1-}" ] || return 0

alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'

# Colour for root, which inherits none. Accounts created from /etc/skel set
# these in their own ~/.bashrc, which is sourced later and simply wins.
alias ls='ls --color=auto'
alias grep='grep --color=auto'
