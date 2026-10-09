# yefter-ansible-hardening

Ansible playbook and roles that harden a fleet of **Ubuntu** and **RHEL-family** EC2 instances
(a subset of the CIS benchmarks):

1. Disable root SSH login (and password login)
2. Enforce strong SSH settings (limits, logging, modern ciphers, MACs and key exchange)
3. Configure **fail2ban** for sshd
4. Turn on **automatic security updates** (`unattended-upgrades` on Ubuntu, `dnf-automatic` on RHEL)

Nothing is hardcoded: every value is a variable with a safe default (see `roles/*/defaults/main.yml`).

## Problem statement

Hand-hardening servers drifts: one host gets the fix, the next does not. This project turns the
same CIS controls into code that you can dry-run, apply in small batches, audit, and run again
safely, on Ubuntu and RHEL with one playbook.

## Architecture

```
 your laptop / CI                      EC2 fleet (tagged Name=yefter-*, Environment=dev|stage|prod)
 +--------------------+   SSH (key)   +-------------------------------------------+
 | ansible-playbook   | ------------> | role: common            checks OS + user   |
 |  site.yml          |   serial 25%  | role: ssh_hardening     sshd drop-in file  |
 |  verify.yml        |   batches     | role: fail2ban          sshd jail          |
 +---------+----------+               | role: unattended_upgrades  auto updates    |
           |                          +-------------------------------------------+
   inventory/aws_ec2.yml  -> groups: hardening_targets, env_dev, env_stage, env_prod
   inventory/group_vars/  -> per-environment settings (ban times, reboot policy)
```

| Role | What it does |
|---|---|
| `common` | Stops on unsupported OS versions, loads Ubuntu/RHEL names (`ssh` vs `sshd`), refuses to run as root |
| `ssh_hardening` | Writes `/etc/ssh/sshd_config.d/00-yefter-hardening.conf`, validates with `sshd -t`, reloads, then opens a **new** connection to prove you can still log in |
| `fail2ban` | Installs fail2ban (EPEL on RHEL), writes the `[sshd]` jail, enables the service |
| `unattended_upgrades` | Ubuntu: apt periodic + security-only origins. RHEL: `dnf-automatic` with `upgrade_type = security` |
| `verify` | Read-only audit that checks the settings sshd and the services are really using |

### Which CIS area each setting covers

CIS section numbers differ between benchmark versions, so they are named by topic here.

| Control | Setting | Role |
|---|---|---|
| SSH: no root login | `PermitRootLogin no` | `ssh_hardening` |
| SSH: key-based login only | `PasswordAuthentication no`, `PermitEmptyPasswords no` | `ssh_hardening` |
| SSH: limit attempts and idle sessions | `MaxAuthTries`, `LoginGraceTime`, `ClientAlive*`, `MaxSessions`, `MaxStartups` | `ssh_hardening` |
| SSH: logging and banner | `LogLevel VERBOSE`, `Banner` | `ssh_hardening` |
| SSH: strong crypto | `Ciphers`, `MACs`, `KexAlgorithms` | `ssh_hardening` |
| SSH: file permissions | `sshd_config` is `root:root` mode `0600` | `ssh_hardening` |
| SSH: disable forwarding | `X11Forwarding no`, `AllowTcpForwarding no` | `ssh_hardening` |
| Brute-force protection | fail2ban `[sshd]` jail | `fail2ban` |
| Patch management | security updates applied automatically | `unattended_upgrades` |

## Prerequisites

- Control machine: Python 3 and `ansible-core` (`pip install -r requirements.txt`)
- Targets: **Ubuntu 22.04 / 24.04** or **RHEL / Rocky / AlmaLinux 8 or 9**
  - RHEL 8 ships Python 3.6, which `ansible-core` 2.17+ can no longer manage. Use `pip install "ansible-core<2.17"` for RHEL 8.
- A normal sudo user with **SSH key login already working** (`ubuntu` on Ubuntu AMIs, `ec2-user` on RHEL AMIs). The play refuses to run as root.
- Targets must reach package mirrors (a NAT gateway or mirror, like the VPC from Problem 1). On RHEL, fail2ban comes from EPEL.
- For the dynamic inventory only: `ansible-galaxy collection install -r requirements-inventory.yml`, `boto3`, and AWS credentials.

## Usage

```bash
pip install -r requirements.txt

# 1. Tell Ansible who you are (do NOT use root)
export ANSIBLE_REMOTE_USER=ubuntu          # or ec2-user
export ANSIBLE_PRIVATE_KEY_FILE=~/.ssh/<your-key>.pem

# 2. Pick your hosts: edit inventory/hosts.ini, or use the EC2 tags
ansible-inventory -i inventory/aws_ec2.yml --graph

# 3. Dry run first (changes nothing, shows the diff)
ansible-playbook -i inventory/aws_ec2.yml site.yml --check --diff

# 4. Apply to one environment, then everything
ansible-playbook -i inventory/aws_ec2.yml site.yml -e target_hosts=env_dev
ansible-playbook -i inventory/aws_ec2.yml site.yml

# 5. Audit
ansible-playbook -i inventory/aws_ec2.yml verify.yml
```

Useful options:

| Option | Meaning |
|---|---|
| `-e target_hosts=env_prod` | Only that group |
| `-e hardening_serial=1` | One host at a time (default `25%`) |
| `-e hardening_max_fail_percentage=0` | Stop the whole run if any host fails (default `0`) |
| `--tags ssh` / `fail2ban` / `updates` | Run one role |
| `-e '{"fail2ban_ignore_ips": ["127.0.0.1/8", "10.0.0.0/8"]}'` | Never ban your VPN or VPC range |

### Sample inputs

| File | Purpose |
|---|---|
| `inventory/hosts.ini` | Static host list |
| `inventory/aws_ec2.yml` | Dynamic EC2 inventory (region and `yefter-*` Name filter are sample values, edit them) |
| `inventory/group_vars/all.yml` | Settings shared by every host |
| `inventory/group_vars/env_dev.yml`, `env_stage.yml`, `env_prod.yml` | Per-environment overrides, picked up from the instance's `Environment` tag |

| | dev | stage | prod |
|---|---|---|---|
| fail2ban ban time | 600 s | 1800 s | 3600 s |
| failed logins before ban | 5 | 4 | 3 |
| auto reboot (Ubuntu only) | on | off | off |

## Testing and CI

```bash
./scripts/lint.sh                  # yamllint + ansible-lint + syntax checks + template render test
ansible-playbook tests/render.yml  # renders every template and checks SSH settings with the real sshd -t
./scripts/check-idempotency.sh -e target_hosts=env_dev   # applies twice, fails if run 2 changes anything
```

GitHub Actions (`.github/workflows/ci.yml`) runs yamllint, ansible-lint (production profile), syntax checks, and the
render test with the real `sshd` on every pull request.

**Suggested real test:** launch one Ubuntu 24.04 and one RHEL 9 instance (small free-tier types are enough), run
`--check --diff`, apply, run `verify.yml`, run the idempotency script, then terminate the instances.
Keep a second SSH session open the first time you apply.

## Security considerations

- **Lockout protection.** The play refuses to run as root, validates the sshd config twice (`sshd -t -f` on the new file and `sshd -t` on the whole config) before reloading, and opens a fresh connection afterwards to prove login works. With `serial`, a failure stops the rollout after the first batch.
- **AllowGroups safety.** If you set `ssh_hardening_allow_groups`, the play checks that the Ansible user is in one of those groups first.
- **Drop-in file, not a rewrite.** The main `sshd_config` is only touched to add an `Include` line (if missing) and to set mode `0600`. The settings live in `00-yefter-hardening.conf`, which loads first because sshd uses the first value it finds.
- **Keys only.** Disabling passwords is safe only if key login works. Test it before the first run.
- **`AllowTcpForwarding no`** follows the CIS recommendation but blocks `ssh -L` tunnels. Set `ssh_hardening_allow_tcp_forwarding: "yes"` for bastions.
- **fail2ban cannot see through NAT.** If everyone connects from one office or VPN address, add it to `fail2ban_ignore_ips` so one typo cannot ban the whole team. Use security groups for the real network limit.
- **No secrets in the repo.** Keys and credentials come from your environment. `.gitignore` excludes `*.pem` and vault password files.
- **Not included:** firewall rules, auditd, filesystem and kernel parameter controls, and the rest of the CIS benchmark.

## Idempotency notes

- Every task uses a state-based module (`template`, `lineinfile`, `file`, `apt`, `dnf`, `service`). Running the play again changes nothing, which `scripts/check-idempotency.sh` checks.
- `ansible_managed` is a fixed string, so templates do not change on every run.
- `command` tasks (`sshd -t`, `-T`, `fail2ban-client`) are read-only and marked `changed_when: false`.
- Handlers fire only when a file actually changed, so sshd and fail2ban are not reloaded needlessly.
- `--check --diff` is safe on a fresh host. The service and timer tasks tolerate the packages not being installed yet during a dry run.

## Limitations

- **Not verified on live EC2 instances yet.** What was checked: yamllint, ansible-lint (production profile), Ansible syntax checks, the template render test, and the guard and audit logic. `sshd -t` on the rendered file runs in CI. Do the real test above before using this on production.
- Amazon Linux is not supported (fail2ban is not in its default repositories).
- The SSH port is not changed (that is not a CIS control and adds lockout risk), so Ubuntu's `ssh.socket` and SELinux port rules never come into play.
- `unattended_upgrades_auto_reboot` applies to Ubuntu only. On RHEL, use `needs-restarting -r` and your own reboot window.
- Hosts in FIPS mode may reject `chacha20-poly1305`. Override `ssh_hardening_ciphers`.
- fail2ban reads sshd's journal entries (`journalmatch`). After the first run, check `fail2ban-client status sshd`, then confirm a ban by failing a few logins from a test machine.
