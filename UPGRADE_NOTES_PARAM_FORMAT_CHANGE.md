# Upgrade notes — parameter & template format changes

This document summarizes the parameter and seed-template format changes introduced recently. It is intended to help you update existing parameter files and templates and to verify outputs before applying changes to any important systems.

---

## Summary of notable changes
- Multi-user support: define users as `user1`, `user2`, ... blocks in the parameter file. Each block can contain name, groups, password/password_hash, ssh_keys, and a `primary: true` flag to choose the primary user for in-guest operations.
- Per-user SSH key placement: user-data templates now support per-user placeholders (e.g., `{{user1.SSH_KEYS}}`) so each user can have its own `ssh_authorized_keys` block.
- DNS (nameservers) flexibility: network interface DNS entries can be specified as a single value or as an array in parameters; templates receive a safe bracketed representation (e.g., `[192.0.2.1, 192.0.2.2]`) for Netplan/cloud-init nameservers.
- Swaps mapping: the previous `resize_swap` array was consolidated to a `swaps` mapping (numeric keys recommended) to guarantee stable ordering when processing multiple swap devices.

## Compatibility and automatic mapping
- The script performs an automatic compatibility mapping: when `user1`, `user2`, ... are present the script selects the `primary: true` user (or the first defined user if none marked `primary`) and copies that user's `name` and `password` into the legacy top-level `username` and `password` parameters. This keeps existing in-guest operations (Invoke‑VMScript, etc.) working without further changes.
- Note: although this mapping preserves runtime compatibility, templates must be updated to reference per-user placeholders where appropriate.

## Important practical notes
- Avoid testing template personalization on production VMs. The recommended verification below generates the seed files only and avoids reapplying personalization to a VM.
- The new format no longer emits a single top-level `SSH_KEYS` placeholder — use per-user placeholders (e.g., `{{user1.SSH_KEYS}}`) in `user-data_template.yaml`.
- If a `userN.ssh_keys` list is empty or missing, the script will emit an explicit empty array (`[]`) for that placeholder so templates remain valid YAML. Keep your template indentation consistent with the script's expected formatting (the script currently emits per-key lines indented to align with the template's `ssh_authorized_keys` list).
- Define `swaps` as a mapping with numeric-like keys for predictable ordering, for example:
  ```yaml
  swaps:
    1: /dev/sdb1
    2: /dev/sdc1
  ```

## Quick verification (recommended)
To verify outputs safely without reapplying personalization to a VM, run Phase 3 only with `-NoRestart`. The goal is to confirm the rendered seed files, not to modify a running system:

```powershell
.\cloudinit-linux-vm-deploy.ps1 -Phase 3 -Config .\params\<your_params>.yaml -NoRestart
```

Then inspect:
- `spool/<new_vm_name>/cloudinit-seed/user-data`
- `spool/<new_vm_name>/cloudinit-seed/network-config`

Check: YAML syntax, `ssh_authorized_keys` entries, `nameservers` representation, and any generated `runcmd` / swap handling script embedded in user-data.

**Do not** perform this verification on a production VM where personalization reapplication (reboots or cloud-init re-run) could have side effects.

## Representative migration examples for parameter file

- Single top-level (old) -> `user1` (new)

  Old (top-level):
  ```yaml
  username: mainte
  password: "Secret123"
  ssh_keys:
    - "ssh-rsa AAAA... mainte@ws"
  ```

  New:
  ```yaml
  user1:
    primary: true
    name: mainte
    password: "Secret123"
    ssh_keys:
      - "ssh-rsa AAAA... mainte@ws"
  ```

- Multiple users example:
  ```yaml
  user1:
    primary: true
    name: admin01
    groups: "wheel,adm"
    password: "AdminPass123!"
    ssh_keys:
      - "ssh-rsa AAAA... admin01@workstation"

  user2:
    name: deploy
    groups: "wheel"
    ssh_keys:
      - "ssh-rsa AAAA... deploy@ci"
  ```
  The correspinding user2 block in `user-data_template.yaml` must be uncommented:
  ```yaml
    - name: {{user2.name}}
      groups: {{user2.groups}}
      lock_passwd: false
      passwd: {{user2.password_hash}}
      ssh_authorized_keys:
  {{user2.SSH_KEYS}}    #No need to comment-out even if user2.ssh_keys list is empty
      shell: /bin/bash
  ```

- Network nameservers:
  ```yaml
  netif1:
    netdev: ens192
    ip_addr: 192.168.0.10
    prefix: 24
    gateway: 192.168.0.254
    dnsaddresses:
      - 192.168.0.201
      - 192.168.0.202
  ```
  This will be substituted into the template as:
  ```
  nameservers:
    addresses: [192.168.0.201, 192.168.0.202]
  ```

## Template update pointers
- user-data_template.yaml:
  - Replace references to legacy top-level SSH key placeholders with per-user placeholders where appropriate (e.g., `{{user1.SSH_KEYS}}`). Ensure the indentation of the generated SSH key lines in the template matches the script (the script emits the SSH key lines with the indentation expected by the template).
- network-config_template.yaml:
  - Confirm placeholders like `{{netif1.DNS_ADDRESSES}}` are present where nameserver arrays are expected.

## Checklist before running full deployment
- [ ] Update params to `userN` format as needed and mark the intended primary user with `primary: true`.
- [ ] Update templates to use per-user SSH key placeholders.
- [ ] Run Phase 3 with `-NoRestart` and validate `spool/<new_vm_name>/cloudinit-seed/*`.
- [ ] After verifying seed files, run the full flow (Phase 1→4) on a non-production test VM first.

## Notes and history
- Earlier `_multiuser` variant files and separate deep-dive implementation documents were consolidated and removed in favor of a single canonical template set and this upgrade note. If you need the previous variant files or implementation notes, check the repository commit history or the merged PR that introduced these changes.

---  
If you find any unexpected output in the generated seed files, save the generated `user-data` / `network-config` snippets and compare them to your template/params inputs; that will make troubleshooting straightforward. This document is a concise migration aid; it does not guarantee instant support availability.

