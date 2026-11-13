"""
CoRoute deploy inventory loader (v3.56 round 6).

Real addresses, OCIDs, e-mail addresses and key paths never live in tracked files. Scripts read them from the
environment or from the git-ignored deploy/inventory.local.env (template: deploy/inventory.example.env):

    from _inventory import inv, inv_list
    ADB_ID = inv("OCI_ADB_OCID")                      # exits with a clear message when missing
    EXTRA  = inv_list("ADB_ACL_EXTRA_IPS", required=False)

Lookup order: process environment, then COROUTE_INVENTORY (a file path), then deploy/inventory.local.env.
Placeholders of the template ("<...>") count as missing.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_CACHE = None


def _parse(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key = key.strip()
                if key.startswith("export "):
                    key = key[len("export "):].strip()
                val = val.strip()
                if val[:1] in ("'", '"'):
                    q = val[0]
                    end = val.find(q, 1)
                    val = val[1:end] if end > 0 else val[1:]
                else:
                    val = val.split(" #", 1)[0].split("\t#", 1)[0].strip()
                out[key] = val
    except OSError:
        pass
    return out


def inventory_path():
    return os.environ.get("COROUTE_INVENTORY") or os.path.join(_HERE, "inventory.local.env")


def _file_values():
    global _CACHE
    if _CACHE is None:
        _CACHE = _parse(inventory_path())
    return _CACHE


def _missing(val):
    return val is None or val == "" or (val.startswith("<") and val.endswith(">"))


def inv(name, default=None, required=True):
    """The value of NAME from the environment or the local inventory; exits with a clear message when missing."""
    val = os.environ.get(name)
    if _missing(val):
        val = _file_values().get(name)
    if _missing(val):
        if default is not None or not required:
            return default
        sys.stderr.write(
            f"[inventory] {name} is not set.\n"
            f"  Set it in the environment or in {inventory_path()}\n"
            f"  (copy deploy/inventory.example.env to deploy/inventory.local.env and fill it in; that file is git-ignored).\n"
        )
        sys.exit(2)
    return val


def inv_list(name, required=True):
    """A comma / space separated value as a list."""
    val = inv(name, required=required)
    if not val:
        return []
    return [x for x in val.replace(",", " ").split() if x]


def inv_file_text(name, required=True):
    """The text of the file named by NAME (e.g. an SSH public key file)."""
    path = inv(name, required=required)
    if not path:
        return None
    path = os.path.expanduser(path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as e:
        sys.stderr.write(f"[inventory] {name}={path}: cannot read ({e}).\n")
        sys.exit(2)
