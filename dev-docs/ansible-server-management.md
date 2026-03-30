# Ansible Server Management Plan

Ansible-based automation to run maintenance commands across all inventory servers, supporting both individual command execution and sequenced daily/weekly stacks with colored terminal output for failure notifications.

**User documentation:** See [Ansible Server Management](../external_wiki/Ansible-Server-Management) in the wiki.

## Requirements Summary

| Aspect | Decision |
|--------|----------|
| Target | All servers in Ansible inventory |
| Individual commands | `chezmoi update`, `dcms`, `upd -y` |
| Daily stack | `chezmoi update` → `dcms` → `upd -y` (stop on failure) |
| Weekly stack | Same as daily but `upd -cy` (includes cleanup) |
| Failure handling | Stop sequence, colored terminal output with server/command details |
| Notification | Terminal output with colors showing which server failed and why |

## Commands Reference

| Command | Purpose | Location on servers |
|---------|---------|---------------------|
| `chezmoi update` | Update dotfiles from source | `~/.local/bin/chezmoi` (via Homebrew) |
| `dcms` | Update all Docker Compose setups under `~/servers` | `~/.local/bin/dcms` |
| `upd -y` | Update software, auto-confirm prompts | `~/.local/bin/upd` |
| `upd -cy` | Update software + run cleanup (`cln`) | `~/.local/bin/upd` with `-c` flag |

## Ansible Structure

```
ansible/
├── ansible.cfg              # Config: host_key_checking, pipelining, output format
├── inventory.ini            # Server inventory (or use existing inventory)
├── group_vars/
│   └── all.yml             # Common vars: user, paths
├── playbooks/
│   ├── command-chezmoi.yml  # chezmoi update only
│   ├── command-dcms.yml     # dcms only
│   ├── command-upd.yml      # upd -y only (parameterized for -c flag)
│   ├── stack-daily.yml      # Daily sequence with fail-fast
│   └── stack-weekly.yml     # Weekly sequence with cleanup
└── roles/
    └── maintenance/
        ├── tasks/
        │   ├── chezmoi.yml
        │   ├── dcms.yml
        │   └── upd.yml
        └── defaults/
            └── main.yml
```

## Implementation Details

### 1. Ansible Configuration

**ansible.cfg:**
```ini
[defaults]
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
bin_ansible_callbacks = True

[ssh_connection]
pipelining = True
control_path = /tmp/ansible-ssh-%%h-%%p-%%r
```

### 2. Inventory Setup

Use existing inventory or create minimal `inventory.ini`:
```ini
[servers]
# Add your servers here, or use existing inventory path
# server1 ansible_host=192.168.1.10
# server2 ansible_host=192.168.1.11

[servers:vars]
ansible_user={{ lookup('env', 'USER') }}
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

**Note:** If inventory already exists elsewhere, use `-i /path/to/inventory` flag.

### 3. Individual Command Playbooks

Each command gets its own playbook for manual runs:

**command-chezmoi.yml:**
```yaml
---
- name: Run chezmoi update
  hosts: all
  gather_facts: no
  tasks:
    - name: Execute chezmoi update
      ansible.builtin.command: chezmoi update
      register: chezmoi_result
      changed_when: chezmoi_result.rc == 0
      failed_when: chezmoi_result.rc != 0
```

**command-dcms.yml:**
```yaml
---
- name: Run dcms (dcm for all servers)
  hosts: all
  gather_facts: no
  tasks:
    - name: Execute dcms
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/dcms"
      register: dcms_result
      changed_when: true  # Always reports changed as it updates
      failed_when: dcms_result.rc != 0
```

**command-upd.yml:**
```yaml
---
- name: Run upd
  hosts: all
  gather_facts: no
  vars:
    upd_flags: "-y"  # Override with -cy for weekly
  tasks:
    - name: Execute upd
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/upd {{ upd_flags }}"
      register: upd_result
      changed_when: true
      failed_when: upd_result.rc != 0
```

### 4. Stack Playbooks (Daily/Weekly)

**Key requirement:** Stop on first failure, report which server and command failed.

**stack-daily.yml:**
```yaml
---
- name: Daily maintenance stack
  hosts: all
  gather_facts: no
  serial: 1  # Run on one server at a time for clearer failure attribution
  any_errors_fatal: true  # Stop on first error
  tasks:
    - name: chezmoi update
      ansible.builtin.command: chezmoi update
      register: result
      failed_when: result.rc != 0

    - name: dcms
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/dcms"
      register: result
      failed_when: result.rc != 0

    - name: upd -y
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/upd -y"
      register: result
      failed_when: result.rc != 0
```

**stack-weekly.yml:**
```yaml
---
- name: Weekly maintenance stack (with cleanup)
  hosts: all
  gather_facts: no
  serial: 1
  any_errors_fatal: true
  tasks:
    - name: chezmoi update
      ansible.builtin.command: chezmoi update
      register: result
      failed_when: result.rc != 0

    - name: dcms
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/dcms"
      register: result
      failed_when: result.rc != 0

    - name: upd -cy (with cleanup)
      ansible.builtin.command: "{{ ansible_env.HOME }}/.local/bin/upd -cy"
      register: result
      failed_when: result.rc != 0
```

### 5. Colored Terminal Output

Ansible's default output with `stdout_callback = yaml` provides readable output. For enhanced colors, use environment variable:

```bash
export ANSIBLE_FORCE_COLOR=true
```

Or add to `ansible.cfg`:
```ini
[defaults]
force_color = 1
```

**Sample failure output:**
```
TASK [chezmoi update] ********************************************************
fatal: [server1]: FAILED! => changed=true
  cmd: chezmoi update
  rc: 1
  stderr: 'chezmoi: source state does not exist'
  stderr_lines:
    - 'chezmoi: source state does not exist'

PLAY RECAP *********************************************************************
server1                    : ok=0    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
server2                    : ok=0    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
```

### 6. Wrapper Scripts for Easy Execution

Create wrapper scripts in `~/.local/bin/` for convenience:

**ansible-chezmoi:**
```bash
#!/usr/bin/env bash
set -euo pipefail
export ANSIBLE_FORCE_COLOR=true
ansible-playbook -i ~/ansible/inventory.ini ~/ansible/playbooks/command-chezmoi.yml "$@"
```

**ansible-dcms:**
```bash
#!/usr/bin/env bash
set -euo pipefail
export ANSIBLE_FORCE_COLOR=true
ansible-playbook -i ~/ansible/inventory.ini ~/ansible/playbooks/command-dcms.yml "$@"
```

**ansible-upd:**
```bash
#!/usr/bin/env bash
set -euo pipefail
export ANSIBLE_FORCE_COLOR=true
ansible-playbook -i ~/ansible/inventory.ini ~/ansible/playbooks/command-upd.yml "$@"
```

**ansible-daily:**
```bash
#!/usr/bin/env bash
set -euo pipefail
export ANSIBLE_FORCE_COLOR=true
ansible-playbook -i ~/ansible/inventory.ini ~/ansible/playbooks/stack-daily.yml "$@"
```

**ansible-weekly:**
```bash
#!/usr/bin/env bash
set -euo pipefail
export ANSIBLE_FORCE_COLOR=true
ansible-playbook -i ~/ansible/inventory.ini ~/ansible/playbooks/stack-weekly.yml "$@"
```

## Usage Examples

### Manual Individual Commands

```bash
# Update dotfiles on all servers
ansible-chezmoi

# Update Docker Compose setups on all servers
ansible-dcms

# Run software updates on all servers
ansible-upd

# Run software updates with cleanup (weekly style)
ansible-upd -e "upd_flags=-cy"
```

### Daily Stack

```bash
# Run full daily sequence: chezmoi → dcms → upd -y
ansible-daily
```

### Weekly Stack

```bash
# Run weekly sequence with cleanup: chezmoi → dcms → upd -cy
ansible-weekly
```

### Limit to Specific Server

```bash
# Run on specific server only
ansible-daily --limit server1
```

### Dry Run (Check Mode)

```bash
# See what would happen without executing
ansible-daily --check
```

## Future: Automation Scheduling

When ready to automate, add cron/systemd timer:

**Daily cron (at 3 AM):**
```cron
0 3 * * * /home/user/.local/bin/ansible-daily >> /home/user/.local/share/logs/ansible-daily.log 2>&1
```

**Weekly cron (Sundays at 4 AM):**
```cron
0 4 * * 0 /home/user/.local/bin/ansible-weekly >> /home/user/.local/share/logs/ansible-weekly.log 2>&1
```

Or use systemd timers for better logging and failure handling.

## Prerequisites Checklist

Before running playbooks, ensure:

- [ ] Ansible installed on control machine (already done per user)
- [ ] SSH key-based auth configured to all target servers
- [ ] `chezmoi`, `dcm`, `upd` utilities deployed on all target servers
- [ ] `~/servers` directory exists on servers that run Docker Compose
- [ ] Inventory file created with all target servers listed
- [ ] Test connectivity: `ansible all -i inventory.ini -m ping`

## Failure Scenarios and Output

| Scenario | Expected Output |
|----------|-----------------|
| chezmoi fails on server1 | Red fatal error, server1 shows FAILED, server2+ show skipped for remaining tasks |
| dcms fails | Same pattern, command-specific stderr shown |
| upd fails | Same pattern, package manager errors visible |
| SSH connection fails | Purple "UNREACHABLE!" message with SSH error details |

## Open Questions (None)

All clarifications resolved:
- ✅ Target: All servers in inventory
- ✅ `dcms` is the wrapper script (not `dcm --all`)
- ✅ Notification: Terminal output with colors
- ✅ Weekly difference: `upd -cy` (with cleanup flag)

## File Locations

Store all Ansible files in this chezmoi project:

```
dotfiles/
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini
│   └── playbooks/
│       ├── command-chezmoi.yml
│       ├── command-dcms.yml
│       ├── command-upd.yml
│       ├── stack-daily.yml
│       └── stack-weekly.yml
```

Use `dot_` prefix if deploying to `~/ansible/`, or reference from chezmoi source directly.
