#!/usr/bin/env python3
"""
Terp Network Node Installer

Thin wrapper that downloads the terpd binary, collects user preferences
via interactive prompts, then delegates all node setup to `terpd bootstrap`.

Usage:
    python3 terp-installer.py
    python3 terp-installer.py --version v5.0.0
    python3 terp-installer.py --help
"""

import argparse
import os
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import urllib.error

# ─── Constants ───────────────────────────────────────────────────────────────

GITHUB_REPO = "terpnetwork/terp-core"
BINARY_NAME = "terpd"
DEFAULT_VERSION = "v5.0.0"

NETWORKS = {
    "morocco-1": {
        "name": "Mainnet (morocco-1)",
        "chain_id": "morocco-1",
    },
    "90u-4": {
        "name": "Testnet (90u-4)",
        "chain_id": "90u-4",
    },
}

PRUNING_OPTIONS = {
    "1": ("default", "Keep recent state + periodic snapshots (recommended)"),
    "2": ("nothing", "Keep all state (archival node, uses most disk)"),
    "3": ("everything", "Prune aggressively (minimal disk, no historical queries)"),
}


# ─── Helpers ─────────────────────────────────────────────────────────────────

def clear_screen():
    os.system("cls" if os.name == "nt" else "clear")


def welcome_message():
    clear_screen()
    print(r"""
 ___________                    _______          __
 \__    ___/___________  ____   \      \   _____/  |___  _  _____________  __
   |    | /  __ \_  __ \|  _ \  /   |   \_/ __ \   __\ \/ \/ /  _ \_  __ |/ /
   |    |\  ___/|  | \/|  |_) )/    |    \  ___/|  |  \     (  (_) )  | \/  <
   |____| \___  >__|   |  __/ \____|__  /\___  >__|   \/\_/ \____/|__|  |__|
              \/       |__|           \/     \/

  Terp Network Node Installer
  https://terp.network
    """)


def prompt_choice(prompt, options, default=None):
    """Display numbered options and return the user's choice."""
    print(f"\n{prompt}")
    for key, (label, desc) in options.items():
        marker = " (*)" if key == default else ""
        print(f"  {key}) {label} — {desc}{marker}")

    while True:
        choice = input(f"\nEnter choice [{default or ''}]: ").strip()
        if not choice and default:
            return default
        if choice in options:
            return choice
        print(f"Invalid choice. Please enter one of: {', '.join(options.keys())}")


def prompt_yes_no(prompt, default=True):
    """Simple yes/no prompt."""
    hint = "[Y/n]" if default else "[y/N]"
    answer = input(f"{prompt} {hint}: ").strip().lower()
    if not answer:
        return default
    return answer in ("y", "yes")


def prompt_string(prompt, default=""):
    """Prompt for a string value with optional default."""
    if default:
        answer = input(f"{prompt} [{default}]: ").strip()
        return answer if answer else default
    while True:
        answer = input(f"{prompt}: ").strip()
        if answer:
            return answer
        print("Please enter a value.")


def detect_platform():
    """Detect OS and architecture for binary download."""
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "darwin":
        os_name = "darwin"
    elif system == "linux":
        os_name = "linux"
    else:
        print(f"Error: Unsupported OS: {system}")
        sys.exit(1)

    if machine in ("x86_64", "amd64"):
        arch = "amd64"
    elif machine in ("aarch64", "arm64"):
        arch = "arm64"
    else:
        print(f"Error: Unsupported architecture: {machine}")
        sys.exit(1)

    return os_name, arch


def download_binary(version, dest_dir):
    """Download the terpd binary from GitHub releases."""
    os_name, arch = detect_platform()

    # Release tarball naming: terpd-<version>-<os>-<arch>.tar.gz
    tarball = f"terpd-{version}-{os_name}-{arch}.tar.gz"
    url = f"https://github.com/{GITHUB_REPO}/releases/download/{version}/{tarball}"

    print(f"\nDownloading {BINARY_NAME} {version} for {os_name}/{arch}...")
    print(f"  URL: {url}")

    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp:
        tmp_path = tmp.name

    try:
        urllib.request.urlretrieve(url, tmp_path)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"\nError: Release {version} not found for {os_name}/{arch}.")
            print(f"Check available releases at: https://github.com/{GITHUB_REPO}/releases")
            sys.exit(1)
        raise

    # Extract the binary
    with tarfile.open(tmp_path, "r:gz") as tar:
        # Look for the terpd binary inside the tarball
        members = tar.getmembers()
        terpd_member = None
        for m in members:
            if m.name.endswith(BINARY_NAME) or os.path.basename(m.name) == BINARY_NAME:
                terpd_member = m
                break

        if terpd_member is None:
            print(f"Error: {BINARY_NAME} not found in release tarball.")
            sys.exit(1)

        # Extract to dest_dir
        terpd_member.name = BINARY_NAME  # flatten path
        tar.extract(terpd_member, dest_dir)

    os.unlink(tmp_path)

    binary_path = os.path.join(dest_dir, BINARY_NAME)
    os.chmod(binary_path, os.stat(binary_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    print(f"  Installed: {binary_path}")
    return binary_path


def install_to_path(binary_path):
    """Copy binary to a directory on PATH (e.g., /usr/local/bin)."""
    install_dir = "/usr/local/bin"
    dest = os.path.join(install_dir, BINARY_NAME)

    if not os.access(install_dir, os.W_OK):
        print(f"\nCopying {BINARY_NAME} to {install_dir} (requires sudo)...")
        subprocess.run(["sudo", "cp", binary_path, dest], check=True)
        subprocess.run(["sudo", "chmod", "+x", dest], check=True)
    else:
        shutil.copy2(binary_path, dest)
        os.chmod(dest, os.stat(dest).st_mode | stat.S_IEXEC)

    print(f"  {BINARY_NAME} available at: {dest}")
    return dest


def patch_client_toml(home, chain_id):
    """Minimal client.toml patching for client-only install."""
    client_toml = os.path.join(home, "config", "client.toml")
    if not os.path.exists(client_toml):
        return

    with open(client_toml, "r") as f:
        content = f.read()

    # Set chain-id and a reasonable RPC endpoint
    rpc = "https://rpc.terp.network:443"
    if chain_id == "90u-4":
        rpc = "https://testnet-rpc.terp.network:443"

    content = content.replace('chain-id = ""', f'chain-id = "{chain_id}"')
    content = content.replace('node = "tcp://localhost:26657"', f'node = "{rpc}"')

    with open(client_toml, "w") as f:
        f.write(content)

    print(f"  client.toml updated (chain-id={chain_id}, node={rpc})")


# ─── Install Flows ──────────────────────────────────────────────────────────

def install_node(args):
    """Full node installation: download binary + delegate to terpd bootstrap."""
    # Select network
    network_choices = {
        "1": ("morocco-1", "Mainnet — production network"),
        "2": ("90u-4", "Testnet — test network"),
    }
    net_key = prompt_choice("Which network?", network_choices, default="1")
    network = network_choices[net_key][0]
    chain_id = NETWORKS[network]["chain_id"]
    print(f"  Selected: {NETWORKS[network]['name']}")

    # Download binary
    version = args.version
    with tempfile.TemporaryDirectory() as tmpdir:
        binary_path = download_binary(version, tmpdir)
        installed_path = install_to_path(binary_path)

    # Node home directory
    default_home = os.path.expanduser("~/.terp")
    home = prompt_string("\nNode home directory", default=default_home)

    # Moniker
    moniker = prompt_string("Node moniker (display name)")

    # Pruning
    pruning_key = prompt_choice("Pruning strategy", PRUNING_OPTIONS, default="1")
    pruning = PRUNING_OPTIONS[pruning_key][0]

    # Cosmovisor
    cosmovisor = prompt_yes_no("\nInstall cosmovisor for automatic upgrades?", default=False)

    # Systemd service (Linux only)
    service = False
    if platform.system() == "Linux":
        service = prompt_yes_no("Create systemd service?", default=False)

    # Build the bootstrap command
    cmd = [
        installed_path, "bootstrap",
        "--network", chain_id,
        "--home", home,
        "--moniker", moniker,
        "--pruning", pruning,
    ]
    if cosmovisor:
        cmd.append("--cosmovisor")
    if service:
        cmd.append("--service")

    print(f"\n{'─' * 60}")
    print("Running: " + " ".join(cmd))
    print(f"{'─' * 60}\n")

    # Delegate to terpd bootstrap — it handles init, genesis, peers, sync, start
    try:
        os.execvp(cmd[0], cmd)
    except FileNotFoundError:
        print(f"Error: {cmd[0]} not found. Is it installed correctly?")
        sys.exit(1)


def install_client(args):
    """Client-only installation: binary + init + config."""
    # Select network
    network_choices = {
        "1": ("morocco-1", "Mainnet — production network"),
        "2": ("90u-4", "Testnet — test network"),
    }
    net_key = prompt_choice("Which network?", network_choices, default="1")
    network = network_choices[net_key][0]
    chain_id = NETWORKS[network]["chain_id"]

    # Download binary
    version = args.version
    with tempfile.TemporaryDirectory() as tmpdir:
        binary_path = download_binary(version, tmpdir)
        installed_path = install_to_path(binary_path)

    # Node home directory
    default_home = os.path.expanduser("~/.terp")
    home = prompt_string("\nClient home directory", default=default_home)

    # Moniker
    moniker = prompt_string("Client name")

    # Init
    print(f"\nInitializing client config...")
    subprocess.run(
        [installed_path, "init", moniker, "--chain-id", chain_id, "--home", home],
        check=True,
    )

    # Patch client.toml
    patch_client_toml(home, chain_id)

    print(f"\n{'─' * 60}")
    print(f"Client setup complete!")
    print(f"  Home    : {home}")
    print(f"  Chain ID: {chain_id}")
    print(f"\nYou can now run:")
    print(f"  terpd status --home {home}")
    print(f"  terpd query bank balances <address> --home {home}")
    print(f"{'─' * 60}")


def install_localterp(args):
    """Local development chain (single validator)."""
    version = args.version
    with tempfile.TemporaryDirectory() as tmpdir:
        binary_path = download_binary(version, tmpdir)
        installed_path = install_to_path(binary_path)

    home = os.path.expanduser("~/.terp-local")
    print(f"\nStarting local development chain at {home}...")
    print("This will create a single-validator chain for testing.\n")

    subprocess.run(
        [installed_path, "init", "localterp", "--chain-id", "localterp-1", "--home", home],
        check=True,
    )

    print(f"\n{'─' * 60}")
    print(f"Local chain initialized at {home}")
    print(f"Start with: terpd start --home {home}")
    print(f"{'─' * 60}")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Terp Network Node Installer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--version", default=DEFAULT_VERSION,
        help=f"terpd version to install (default: {DEFAULT_VERSION})",
    )
    args = parser.parse_args()

    welcome_message()

    install_types = {
        "1": ("Node", "Full node — sync with the network and validate"),
        "2": ("Client", "Client only — query the chain, no syncing"),
        "3": ("LocalTerp", "Local dev chain — single validator for testing"),
    }

    choice = prompt_choice("What would you like to install?", install_types, default="1")

    if choice == "1":
        install_node(args)
    elif choice == "2":
        install_client(args)
    elif choice == "3":
        install_localterp(args)


if __name__ == "__main__":
    main()
