# Copyright (C) 2026 Panopticom
# SPDX-License-Identifier: GPL-3.0-or-later

{ config, pkgs, lib, inputs, ... }:

let
  cfg = config.panopticom.autoUpdate;
  allInputNames = lib.filter (n: n != "self") (builtins.attrNames inputs);
  inputsToUpdate = lib.filter (i: !(lib.elem i cfg.pinnedInputs)) allInputNames;
  hasWebhooks = cfg.webhookFiles != [];
  hostname = config.networking.hostName;
in {
  imports = [
    (lib.mkRenamedOptionModule
      [ "panopticom" "autoUpdate" "dates" ]
      [ "panopticom" "autoUpdate" "schedule" ])
  ];

  options.panopticom.autoUpdate = {
    enable = lib.mkEnableOption "automatic NixOS upgrades";

    gitRepoUrl = lib.mkOption {
      type = lib.types.str;
      description = "Git repository URL to pull before upgrading.";
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = "Path to SSH private key for authenticating git pull.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "Mon 12:00";
      description = "Systemd calendar expression for when to run upgrades.";
    };

    pinnedInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Flake inputs to exclude from automatic updates.";
    };

    webhookFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Paths to files containing webhook URLs to notify after upgrade.";
    };

    uncommittedChanges = lib.mkOption {
      type = lib.types.enum [ "discard" "commit" "fail" ];
      default = "discard";
      description = ''
        How to handle uncommitted local changes in /etc/nixos before pulling.
        - discard: reset hard to origin/main, discarding all local changes
        - commit: commit and push local changes, then pull --rebase
        - fail: abort if there are uncommitted changes (default git behavior)
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos";
      dates = cfg.schedule;
      allowReboot = false;
    };

    systemd.services.nixos-upgrade = {
      onFailure = lib.mkIf hasWebhooks [ "nixos-upgrade-notify-failure.service" ];
      serviceConfig = {
        ExecStartPre =
          let
            git = "${pkgs.git}/bin/git -C /etc/nixos";
            gitCmd = {
              discard = ''
                DISCARDED=$(${git} status --short 2>/dev/null || true)
                [ -n "$DISCARDED" ] && echo "$DISCARDED" > /tmp/nixos-upgrade-discarded || rm -f /tmp/nixos-upgrade-discarded
                ${git} fetch $REMOTE main
                ${git} reset --hard FETCH_HEAD
              '';
              commit = ''
                ${git} config user.email "auto-upgrade@localhost"
                ${git} config user.name "${hostname}"
                ${git} add -A
                ${git} diff --quiet --cached || ${git} commit -m "chore: save local changes on ${hostname}"
                ${git} pull --rebase $REMOTE main
                ${git} push $REMOTE main
              '';
              fail = ''
                ${git} pull $REMOTE main
              '';
            }.${cfg.uncommittedChanges};
            flakeUpdateCmd = "${pkgs.nix}/bin/nix flake update --flake /etc/nixos ${lib.concatStringsSep " " inputsToUpdate}";
            preScript = pkgs.writeShellScript "nixos-upgrade-pre" ''
              set -euo pipefail
              if [ -f "${cfg.sshKeyFile}" ]; then
                export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i ${cfg.sshKeyFile} -o StrictHostKeyChecking=accept-new"
                REMOTE="${cfg.gitRepoUrl}"
              else
                REMOTE=$(printf '%s' "${cfg.gitRepoUrl}" | ${pkgs.gnused}/bin/sed 's|git@\(.*\):\(.*\)|https://\1/\2|')
              fi
              date +%s > /tmp/nixos-upgrade-start-time
              readlink -f /nix/var/nix/profiles/system > /tmp/nixos-upgrade-old-profile
              ${git} rev-parse HEAD > /tmp/nixos-upgrade-old-head 2>/dev/null || echo "" > /tmp/nixos-upgrade-old-head
              ${gitCmd}
              ${flakeUpdateCmd}
            '';
          in "${preScript}";

        ExecStartPost =
          let
            discordNotify = ''
              if [ -n "$DIFF" ]; then
                PKG_STATS=$(printf '%s' "$DIFF" | ${pkgs.gawk}/bin/awk '
                  / → / && !/ε → / && !/→ ∅/ { updated++ }
                  /ε → /                       { added++ }
                  /→ ∅/                        { removed++ }
                  match($0, /([+-][0-9]+\.?[0-9]*) KiB/, a) { net += a[1]+0 }
                  END { printf "%d updated, %d added, %d removed, net %+.1f KiB", updated+0, added+0, removed+0, net }
                ')
                PACKAGES_MSG=$(printf '\nPackages Updated (%s):\n```\n%s\n```' "$PKG_STATS" "$(printf '%s' "$DIFF" | tail -c 1200)")
              else
                PACKAGES_MSG=$(printf '\nAll packages up to date.')
              fi
              MSG=$(printf '%s%s%s%s%s%s' "${hostname}: auto-upgrade completed successfully" "$STATS_MSG" "$COMMITS_MSG" "$DISCARDED_MSG" "$RESTARTED_MSG" "$PACKAGES_MSG")
              PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg msg "$MSG" '{"content": $msg}')
            '' + lib.concatMapStrings (webhookFile: ''
              ${pkgs.curl}/bin/curl -s -X POST "$(cat ${webhookFile})" \
                -H "Content-Type: application/json" \
                -d "$PAYLOAD"
            '') cfg.webhookFiles;
            postScript = pkgs.writeShellScript "nixos-upgrade-post" ''
              if [ -f "${cfg.sshKeyFile}" ]; then
                export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i ${cfg.sshKeyFile} -o StrictHostKeyChecking=accept-new"
                REMOTE="${cfg.gitRepoUrl}"
              else
                REMOTE=$(printf '%s' "${cfg.gitRepoUrl}" | ${pkgs.gnused}/bin/sed 's|git@\(.*\):\(.*\)|https://\1/\2|')
              fi

              # Duration
              END_TIME=$(date +%s)
              START_TIME=$(cat /tmp/nixos-upgrade-start-time 2>/dev/null || echo "$END_TIME")
              DURATION=$(( END_TIME - START_TIME ))
              DURATION_MSG=$(printf '%dm %ds' $(( DURATION / 60 )) $(( DURATION % 60 )))
              rm -f /tmp/nixos-upgrade-start-time

              # Generation number
              GENERATION=$(readlink /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed 's/.*system-\([0-9]*\)-link/\1/')

              # Kernel version / reboot check
              OLD_KERNEL=$(readlink /run/booted-system/kernel 2>/dev/null || true)
              NEW_KERNEL=$(readlink /nix/var/nix/profiles/system/kernel 2>/dev/null || true)
              NEW_KERNEL_VER=$(printf '%s' "$NEW_KERNEL" | ${pkgs.gnused}/bin/sed 's/.*linux-\([0-9][0-9.]*\).*/\1/')
              if [ -n "$OLD_KERNEL" ] && [ "$OLD_KERNEL" != "$NEW_KERNEL" ]; then
                OLD_KERNEL_VER=$(printf '%s' "$OLD_KERNEL" | ${pkgs.gnused}/bin/sed 's/.*linux-\([0-9][0-9.]*\).*/\1/')
                KERNEL_MSG=" | Kernel: ''${OLD_KERNEL_VER} → ''${NEW_KERNEL_VER} (reboot required)"
              else
                KERNEL_MSG=" | Kernel: ''${NEW_KERNEL_VER}"
              fi

              STATS_MSG=$(printf '\nGeneration: %s | Duration: %s%s' "$GENERATION" "$DURATION_MSG" "$KERNEL_MSG")

              # Commits pulled
              OLD_HEAD=$(cat /tmp/nixos-upgrade-old-head 2>/dev/null || true)
              rm -f /tmp/nixos-upgrade-old-head
              COMMITS_MSG=""
              if [ -n "$OLD_HEAD" ]; then
                COMMITS=$(${pkgs.git}/bin/git -C /etc/nixos log "''${OLD_HEAD}..HEAD" --oneline 2>/dev/null || true)
                if [ -n "$COMMITS" ]; then
                  COMMITS_MSG=$(printf '\nCommits Pulled:\n```\n%s\n```' "$COMMITS")
                fi
              fi

              # Discarded local changes
              DISCARDED_MSG=""
              if [ -f /tmp/nixos-upgrade-discarded ] && [ -s /tmp/nixos-upgrade-discarded ]; then
                DISCARDED_MSG=$(printf '\nDiscarded local changes:\n```\n%s\n```' "$(cat /tmp/nixos-upgrade-discarded)")
                rm -f /tmp/nixos-upgrade-discarded
              fi

              # Restarted units
              RESTARTED_MSG=""
              RESTARTED_UNITS=$(${pkgs.systemd}/bin/journalctl "_SYSTEMD_INVOCATION_ID=$INVOCATION_ID" --no-pager -o cat 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "(restarting|starting|stopping) the following units:" || true)
              if [ -n "$RESTARTED_UNITS" ]; then
                RESTARTED_MSG=$(printf '\nUnits Restarted:\n```\n%s\n```' "$RESTARTED_UNITS")
              fi

              # Package diff (computed here so stats can use it)
              DIFF=$(${pkgs.nix}/bin/nix store diff-closures "$(cat /tmp/nixos-upgrade-old-profile)" /nix/var/nix/profiles/system 2>/dev/null | ${pkgs.gnused}/bin/sed 's/\x1b\[[0-9;]*m//g')

              if ! ${pkgs.git}/bin/git -C /etc/nixos diff --quiet flake.lock; then
                ${pkgs.git}/bin/git -C /etc/nixos config user.email "auto-upgrade@localhost"
                ${pkgs.git}/bin/git -C /etc/nixos config user.name "${hostname}"
                ${pkgs.git}/bin/git -C /etc/nixos add flake.lock
                ${pkgs.git}/bin/git -C /etc/nixos commit -m "chore: update flake.lock"
                ${pkgs.git}/bin/git -C /etc/nixos push $REMOTE main
              fi
              ${discordNotify}
            '';
          in "${postScript}";
      };
    };

    systemd.services.nixos-upgrade-notify-failure = lib.mkIf hasWebhooks {
      description = "Notify webhooks of nixos-upgrade failure";
      serviceConfig = {
        Type = "oneshot";
        ExecStart =
          let
            failScript = pkgs.writeShellScript "nixos-upgrade-notify-failure" ''
              LOGS=$(${pkgs.systemd}/bin/journalctl -u nixos-upgrade.service -n 50 --no-pager --output=cat | tail -c 1500)
              ${lib.concatMapStrings (webhookFile: ''
                PAYLOAD=$(${pkgs.jq}/bin/jq -n --arg msg "$(printf '%s\n```\n%s\n```' "${hostname}: auto-upgrade FAILED" "$LOGS")" '{"content": $msg}')
                ${pkgs.curl}/bin/curl -s -X POST "$(cat ${webhookFile})" \
                  -H "Content-Type: application/json" \
                  -d "$PAYLOAD"
              '') cfg.webhookFiles}
            '';
          in "${failScript}";
      };
    };
  };
}
