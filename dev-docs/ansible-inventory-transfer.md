# Ansible Inventory Transfer Plan

Rename `ansible-inventory-export` to `ansible-inventory-transfer`, reading inventory dynamically from `ansible-inventory --list`, using OS-based group names, and accepting target host as a direct parameter.

## Requirements

### 1. Rename Utility
- Rename `ansible-inventory-export` → `ansible-inventory-transfer`
- Update all documentation references (AGENTS.md, ARCHITECTURE.md, llms.txt, wiki pages)

### 2. Read Inventory from Ansible
- Use `ansible-inventory --list` to get current inventory as JSON
- Parse the JSON to extract host groups and members
- No hardcoded host lists

### 3. OS-Based Group Assignment
- Use `uname -s` to detect OS: `Linux` or `Darwin`
- Rename inventory groups to match `uname -s` output:
  - Current `ubuntu` group → `Linux`
  - Current `mac` group → `Darwin`
- Add current host to appropriate group based on OS

### 4. Command Interface
- Target host as direct parameter: `ansible-inventory-transfer <host>`
- No `--to` flag needed
- Example: `ansible-inventory-transfer croc`

### 5. Transfer Logic
1. Read current inventory via `ansible-inventory --list`
2. Determine local OS via `uname -s`
3. Add current hostname to the OS-matching group
4. Remove target host from all groups (if present)
5. Generate new inventory file
6. Copy to target host via SSH: `ssh <host> 'cat > ~/.ansible/hosts'`
7. Print confirmation message

### 6. No Local Writing
- Only transfers to remote hosts
- Does not write to local `~/.ansible/hosts`

## Example Usage

On a Linux machine named `uhop`:
```bash
ansible-inventory-transfer croc
```

This will:
1. Read current inventory
2. Add `uhop` to `Linux` group
3. Remove `croc` from all groups
4. Copy resulting inventory to `croc` via SSH

## Files to Update

- `private_dot_local/bin/executable_ansible-inventory-export` → `executable_ansible-inventory-transfer` (rename and rewrite)
- `AGENTS.md` - update bin/ listing
- `ARCHITECTURE.md` - update bin/ listing  
- `llms.txt` - update documentation
- `external_wiki/Ansible-Server-Management.md` - update usage examples
- `external_wiki/Utilities.md` - update section

## Migration Notes

The inventory file format will change group names from `ubuntu`/`mac` to `Linux`/`Darwin`. Existing playbooks using `hosts: ubuntu` or `hosts: mac` will need to be updated to use `hosts: Linux` or `hosts: Darwin`.
