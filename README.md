# auto-update

A NixOS module that extends `system.autoUpgrade` with git pull, flake input updates, and Discord webhook notifications.

> **Note:** This module expects your NixOS configuration to live at `/etc/nixos` and to be a git repository. It will synchronize `/etc/nixos` with your configured git remote on each upgrade run.

## What it does

On a configurable schedule:

1. Pulls the latest config from git (with configurable handling of uncommitted changes)
2. Updates flake inputs (excluding any pinned ones)
3. Runs `nixos-rebuild switch`
4. Commits and pushes the updated `flake.lock`
5. Sends a webhook with:
   - Generation number, duration, kernel version
   - Commits pulled
   - Discarded local changes (if any)
   - Units restarted
   - Package diff summary

## Usage

Add to your flake:

```nix
inputs.auto-upgrade.url = "github:Panopticom/nixos-auto-update/v1";
```

Add the module and pass `inputs` via `specialArgs` (required for flake input enumeration):

```nix
nixosConfigurations.myhost = lib.nixosSystem {
  modules = [
    auto-upgrade.nixosModules.default
    # ...
  ];
  specialArgs = { inherit inputs; };
};
```

Configure in your host:

```nix
panopticom.autoUpdate = {
  enable = true;
  gitRepoUrl = "git@github.com:youruser/nixos-config";
  schedule = "Mon 12:00";
  pinnedInputs = [ "nixpkgs-stable" ];
  uncommittedChanges = "discard";
  webhookFiles = [
    "/run/secrets/discord-webhook"
  ];
};
```

If you manage secrets with [sops-nix](https://github.com/mic92/sops-nix), you can reference secrets directly for the webhook URLs:

```nix
panopticom.autoUpdate = {
  enable = true;
  gitRepoUrl = "git@github.com:youruser/nixos-config";
  webhookFiles = [
    config.sops.secrets."discord/webhook".path
  ];
};

sops = {
  defaultSopsFile = ./secrets.yaml; # path to your sops-encrypted secrets file
  secrets."discord/webhook" = {};
};
```

The secret file should contain the raw webhook URL as its value. With sops-nix, the decrypted value will be written to a file at runtime (e.g. `/run/secrets/discord/webhook`), which is what `.path` resolves to.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable automatic upgrades |
| `gitRepoUrl` | string | — | Git remote URL (SSH or HTTPS) |
| `sshKeyFile` | string | `/etc/ssh/ssh_host_ed25519_key` | SSH key for git auth. Falls back to HTTPS if not present |
| `schedule` | string | `"Mon 12:00"` | Systemd calendar expression for upgrade schedule |
| `pinnedInputs` | list of string | `[]` | Flake inputs to exclude from `nix flake update` |
| `webhookFiles` | list of string | `[]` | Paths to files containing Discord webhook URLs |
| `uncommittedChanges` | enum | `"discard"` | How to handle local changes before pulling (see below) |

### `uncommittedChanges`

- `discard` — hard reset to `origin/main`, discarding all local changes. Saves a list of discarded files for the webhook notification.
- `commit` — commits and pushes local changes, then pulls with rebase.
- `fail` — aborts if there are any uncommitted changes.

## Security

This module currently runs as root, as it needs to perform `nixos-rebuild switch`, write to `/etc/nixos`, and access the host SSH key. If you have suggestions for a better architecture that reduces the required privileges, please open an issue — input from security experts is very welcome.

## Contributing

If you run into a bug or unexpected behaviour, please [open an issue](https://github.com/Panopticom/nixos-auto-update/issues) with details about what happened and what you expected. Contributions are welcome.
