#!/bin/sh

# Debian login shells replace PATH in /etc/profile. Restore the workstation
# tool and user-install locations without changing the lightweight image.
PATH="/home/node/.local/bin:/home/node/go/bin:/usr/local/go/bin:/home/node/.local/share/pnpm:/opt/dsh/node_modules/.bin:${PATH}"
export PATH
