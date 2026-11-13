#!/usr/bin/env bash
# CoRoute deploy inventory loader for shell scripts (v3.56 round 6). Source it, then call need VAR [VAR...]:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_inventory.sh"; need VM2_PRIVATE_IP VM_SSH_PRIVATE_KEY_FILE
#
# Values come from the environment, else from $COROUTE_INVENTORY, else deploy/inventory.local.env (git-ignored;
# template: deploy/inventory.example.env). Real addresses, OCIDs, e-mail addresses and key paths never live in
# tracked files. A missing value (or a "<placeholder>" of the template) stops the script with a clear message.
_INV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INV_FILE="${COROUTE_INVENTORY:-$_INV_DIR/inventory.local.env}"
if [ -f "$_INV_FILE" ]; then
  # Environment wins over the file: remember what is already set.
  _inv_pre="$(export -p)"
  set -a; . "$_INV_FILE"; set +a
  eval "$_inv_pre"
  unset _inv_pre
fi
need() {
  local v missing=0
  for v in "$@"; do
    case "${!v:-}" in
      ''|'<'*'>')
        echo "[inventory] $v is not set. Set it in the environment or in $_INV_FILE" >&2
        echo "            (cp deploy/inventory.example.env deploy/inventory.local.env and fill it in; it is git-ignored)" >&2
        missing=1;;
    esac
  done
  [ "$missing" = 0 ] || exit 2
}
