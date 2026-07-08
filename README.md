# ccblocks

[![CI](https://github.com/JackOfSpade/ccblocks/actions/workflows/test.yml/badge.svg)](https://github.com/JackOfSpade/ccblocks/actions/workflows/test.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](README.md#platform-support)

```sh
░░      ░░░      ░░       ░░  ░░░░░░░      ░░░      ░░  ░░░░  ░░      ░░
▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒▒▒▒  ▒▒▒▒  ▒  ▒▒▒▒  ▒  ▒▒▒  ▒▒  ▒▒▒▒▒▒▒
▓  ▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓       ▓▓  ▓▓▓▓▓▓  ▓▓▓▓  ▓  ▓▓▓▓▓▓▓     ▓▓▓▓▓      ▓▓
█  ████  █  ████  █  ████  █  ██████  ████  █  ████  █  ███  ████████  █
██      ███      ██       ██       ██      ███      ██  ████  ██      ██
```

Time-shift Claude sessions to match your working hours

---

## How It Works

**Simple concept:**
- Scheduled trigger: `claude -p --safe-mode --model haiku ...`
- Starts new 5-hour block automatically
- Runs through Claude subscription auth only
- Refuses API-key and third-party provider auth
- Zero maintenance after setup

**Example:**
- **Without ccblocks:** Start coding at 9 AM → hit limits at 10 AM → locked out until 2 PM
- **With ccblocks:** Trigger at 6 AM → start coding at 9 AM → spans multiple blocks → more headroom

**Token cost:** intentionally minimal. ccblocks always uses Claude Code's `haiku` model alias with a tiny one-turn prompt.

## How Scheduling Works

ccblocks runs a lightweight trigger every 15 minutes through the OS-native user scheduler:

- **macOS**: LaunchAgent with `StartInterval=900`
- **Linux**: systemd user timer with `OnUnitActiveSec=15min`
- **No schedule file to maintain**: pause/resume controls the scheduler
- **Simple failure handling**: success or failure, the next attempt is just the next 15-minute scheduler tick

Polling every 15 minutes keeps setup simple and avoids missing a new usage window because a fixed clock-time trigger happened while Claude was still rate-limited.

## Quick Start

```bash
# Install via Homebrew
brew install jackofspade/tap/ccblocks

# Run setup
ccblocks setup
```

### Homebrew Distribution

This fork is distributed via its own [personal Homebrew tap](https://github.com/JackOfSpade/homebrew-tap/blob/master/Formula/ccblocks.rb), independent of the upstream [designorant/ccblocks](https://github.com/designorant/ccblocks) tap.

**Platform Support:** macOS and Linux only. Windows is not currently supported ([contribute!](https://github.com/JackOfSpade/ccblocks/issues)).

## Commands

```bash
ccblocks setup                         # Install and configure
ccblocks status                        # Show scheduler and recent activity
ccblocks schedule current              # Show current scheduler status
ccblocks schedule pause                # Disable scheduler
ccblocks schedule resume               # Re-enable scheduler
ccblocks schedule remove               # Remove scheduler files
ccblocks pause                         # Vacation mode
ccblocks resume                        # Resume after vacation
ccblocks uninstall                     # Complete removal
```

## FAQ

**Does this bypass Claude's rate limits?**
No. Your subscription limits still apply. This optimizes *when* your 5-hour windows start.

**Does this use API credits?**
No. ccblocks is designed for Claude subscription users. It refuses to trigger when API-key or third-party provider credentials are present.

**How much does this cost in tokens?**
Each trigger sends a tiny one-turn prompt to Claude Code's cheapest model alias, `haiku`, and expects a short acknowledgement.

**Can I change the timing?**
No. ccblocks now uses fixed 15-minute polling. Use `ccblocks pause` and `ccblocks resume` to control when it runs.

**Why not just use cron or a bash loop?**

You *can* - many users successfully schedule triggers with:
- **Cron**: Simple, but limited logging and error handling
- **Bash loop**: Works in tmux/screen, but manual recovery if it dies

ccblocks provides:
- **Reliability**: Automatic restart, survives reboots
- **Management**: Easy pause/resume and status monitoring
- **Best practices**: OS-native service managers (LaunchAgent/systemd)
- **Observability**: System logs, failure notifications

## Technical Details

**Architecture:**
- **macOS**: LaunchAgent (`~/Library/LaunchAgents/ccblocks.plist`)
- **Linux**: systemd user service (`~/.config/systemd/user/ccblocks@.service`)

**Trigger mechanism:**
1. LaunchAgent/systemd timer fires every 15 minutes
2. Executes `ccblocks-daemon` in your user session
3. Confirms Claude subscription auth is active and API/provider credentials are not present
4. Runs `claude -p --safe-mode --model haiku --max-turns 1 --tools "" --output-format text ...`
5. New 5-hour block starts immediately
6. Logs success/failure to system log

**If the trigger is rejected for hitting a usage limit:** ccblocks does not create a special job or parse reset times. It logs the failure and lets the regular 15-minute scheduler tick make the next attempt.

## Status & Monitoring

```bash
# Check scheduler status
ccblocks status

# View system logs
log show --last 1d --info --predicate 'eventMessage CONTAINS[c] "ccblocks"'    # macOS
journalctl --user -t ccblocks -n 50                       # Linux

# Manual test trigger
ccblocks trigger
```

## Configuration

**Scheduler control:**

```bash
ccblocks schedule current   # Show scheduler status
ccblocks schedule pause     # Disable scheduler
ccblocks schedule resume    # Re-enable scheduler
ccblocks schedule remove    # Remove scheduler files
```

**Vacation mode:**
```bash
ccblocks pause    # Disable all triggers
ccblocks resume   # Re-enable schedule
```

The scheduler configuration remains available when paused.

## Troubleshooting

**Scheduler not running:**

macOS:
```bash
launchctl list | grep ccblocks           # Should show loaded
ls ~/Library/LaunchAgents/ccblocks.plist # Should exist
ccblocks status                          # Check detailed status
```

Linux:
```bash
systemctl --user list-timers | grep ccblocks # Should show active
systemctl --user daemon-reload               # Reload if needed
ccblocks status                              # Check detailed status
```

**Claude CLI issues:**
```bash
which claude          # Verify installation
echo "test" | claude  # Test authentication
```

ccblocks requires Claude CLI to be installed and authenticated.

**Logs and configuration:**
- Config directory: `~/.config/ccblocks/`
- macOS logs: Use `log show` (see Status & Monitoring above)
- Linux logs: Use `journalctl` (see Status & Monitoring above)

## Uninstallation

Homebrew automatically removes schedulers when uninstalling:

```bash
# Uninstall package (automatically cleans up schedulers)
brew uninstall ccblocks

# Optional: Remove user configuration
rm -rf ~/.config/ccblocks
```

## Getting Help

- **Issues**: Report bugs on [GitHub Issues](https://github.com/JackOfSpade/ccblocks/issues) (this fork) or [upstream](https://github.com/designorant/ccblocks/issues)
- **Upstream questions/contact**: [GitHub Discussions](https://github.com/designorant/ccblocks/discussions), [@designorant on X](https://x.com/designorant), or [@designorant.com on BlueSky](https://bsky.app/profile/designorant.com)

## Contributing

Contributions are welcome! For local development, testing, and contribution guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © [@designorant](https://github.com/designorant)

This is a fork maintained by [@JackOfSpade](https://github.com/JackOfSpade); see the [LICENSE](LICENSE) for terms.
