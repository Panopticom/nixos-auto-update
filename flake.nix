# Copyright (C) 2026 Panopticom
# SPDX-License-Identifier: GPL-3.0-or-later
{
  description = "systemd service for automatically syncing against a git repository, updating packages, and reporting the results over webhooks.";

  outputs = { self }: {
    nixosModules.default = import ./module.nix;
  };
}
