# [cloudinit-vm-deploy](https://github.com/Tatsuya-Nonogaki/cloudinit-vm-deploy)

# Cloud-init Ready: Linux VM Deployment Kit on vSphere

> 🔔 **Note:** This repository was split out from the **Straypenguins-Tips-Inventory** collection (original path: [vSphere/cloudinit-vm-deploy](https://github.com/Tatsuya-Nonogaki/Straypenguins-Tips-Inventory/tree/main/vSphere/cloudinit-vm-deploy)). The project grew large enough to justify its own repository; historical copies and prior context remain in the original repository's commit history.
>
> If you arrived here from the Tips Inventory, welcome — this repository now contains the full cloudinit-vm-deploy kit (sources, templates, examples, and documentation). Continue below for the project Overview and usage instructions.

## 🧭 Overview

This kit is designed to enable quick and reproducible deployment of Linux VMs from a **well-prepared** (not an out-of-the-box default) VM Template on vSphere, using the cloud-init framework. The main control program is a PowerShell script: `cloudinit-linux-vm-deploy.ps1`. The workflow is split into four phases:

- **Phase 1:** Create a clone from a VM Template  
- **Phase 2:** Prepare the clone to accept cloud-init  
- **Phase 3:** Generate a cloud-init seed (user-data, meta-data, optional network-config), pack them into an ISO, upload it to a datastore and attach it to the clone's CD drive, then boot the VM and wait for cloud-init to complete  
- **Phase 4:** Detach and remove the seed ISO from the datastore, then place `/etc/cloud/cloud-init.disabled` on the guest to prevent future automatic personalization (can be skipped with `-NoCloudReset`)

📝 **Note — DiskOnly mode**  
The primary workflow remains template → clone → initialization → personalization. In addition, this kit provides an optional extension called **DiskOnly Mode** that lets you reapply only disk expansion (partition/filesystem/swap) on VMs previously deployed with this kit. See [DiskOnly Reapply Mode](#-diskonly-reapply-mode) for details.

### ⚠️ Caution: Parameter and template compatibility notes

**🆕 Note ― `cloudinit-linux-vm-deploy.ps1` since `v0.3.4`:**

- In `templates/user-data_template.yaml`, the cloud-init user password field was changed from `passwd:` to `hashed_passwd:`.  
- In versions up to `v0.3.3`, this kit assumed the primary user’s password on the deployed VM remained the same as on the Template VM, so it could go unnoticed that cloud-init was in practice not reapplying the password for that already-existing user.  
- Since `v0.3.4` adds support for changing the primary user’s password on the final deployed VM independently from the guest-operation password, this behavior is now corrected and the template must be updated in lockstep. If you update `cloudinit-linux-vm-deploy.ps1` to `v0.3.4` or later, update your copied `user-data_template.yaml` as well.

**Note ― `cloudinit-linux-vm-deploy.ps1` since `v0.3.0`:**

- The `vcenter_user` field in `params/vm-settings_*.yaml` is now required.  
  When `vcenter_password` is blank or omitted, the script relies on a [credential store](#admin-host-powershell-environment--windows-is-the-primary-target) but still needs an explicit `vcenter_user` to resolve and cache credentials correctly.

**Note ― `cloudinit-linux-vm-deploy.ps1` between `v0.1.5` and `v0.1.7`:**

- Parameter and seed-template format updates were introduced in this range, including multi-user support, per-user SSH key placement, DNS nameserver handling, and a consolidated `swaps` mapping.  
- When your main script version crosses this range, you must upgrade the parameter files and seed template YAMLs in lockstep with `cloudinit-linux-vm-deploy.ps1`.  
- To verify that they are coordinated correctly, run the script with Phase 3 only and with `-NoRestart` to produce the seed files without reapplying personalization to a VM:
  ```powershell
  .\cloudinit-linux-vm-deploy.ps1 -Phase 3 -Config .\params\.yaml -NoRestart
  ```
- Then inspect `spool//cloudinit-seed/` `user-data` and `network-config` to confirm formatting and indentation.  

  See [UPGRADE_NOTES_PARAM_FORMAT_CHANGE.md](UPGRADE_NOTES_PARAM_FORMAT_CHANGE.md) in this directory for detailed notes and examples.

---

📑 **Table of contents**
- [Overview](#-overview)  
- [Key Points — What This Kit Complements in cloud-init](#-key-points--what-this-kit-complements-in-cloud-init)  
- [Key Files](#-key-files)  
- [Requirements and Pre-setup (admin host and template VM)](#%EF%B8%8F-requirements--pre-setup)  
- [Quick Start](#-quick-start-short-path)  
- [Phases — What Does Each Step Perform?](#-phases--what-does-each-step-perform)  
- [Template Infra: What is Changed and Why](#%EF%B8%8F-template-infra-what-is-changed-and-why)  
- [DiskOnly Reapply Mode](#-diskonly-reapply-mode)  
- [mkisofs / ISO Creation Notes](#-mkisofs--iso-creation-notes)  
- [Operational Recommendations](#-operational-recommendations)  
- [Troubleshooting (common cases)](#-troubleshooting-common-cases)  
- [Logs & Debugging](#-logs--debugging)  
- [References](#-references)  
- [License](#-license)

---

## 🎯 Key Points — What This Kit Complements in cloud-init

This kit assumes the lifecycle: **template → new clone → initialization → personalization**. It complements cloud-init by addressing several practical operational gaps in vSphere deployments:

- Filesystem expansion beyond root: kit-specific handling to reformat/recreate swap and to expand non-root ext2/3/4 filesystems after virtual disk enlargement (LVM is not handled).  
- NetworkManager adjustments for Ethernet connection profiles (for example: disable IPv6, set `ignore-auto-routes` / `ignore-auto-dns` with `nmcli`).  
- Deterministic `/etc/hosts` population while setting `manage_etc_hosts: false` for cloud-init.  
- Template safety: the template VM is configured to avoid accidental cloud-init runs; clones remove that protection during initialization.  
- Admin-host-driven seed ISO lifecycle: generate seed files, create a `cidata` ISO, upload it to a datastore, attach it to the VM, and poll until cloud-init completes (quick-check + completion polling).  
- The script stores logs and generated artifacts under `spool/<new_vm_name>/` on the admin host for auditing and troubleshooting.  
- Use PowerShell `-Verbose` to print detailed internal steps for debugging.

⚠️ **Important:**  
This kit is intended for the template → clone → initialization → personalization workflow. It is not meant as a general-purpose tool to retrofit cloud-init onto arbitrary running production VMs.  
But note there is an exception; the optional [DiskOnly Reapply Mode](#-diskonly-reapply-mode) is provided for safely performing disk-only expansions on VMs originally deployed with this kit.

---

## 📁 Key Files

- `cloudinit-linux-vm-deploy.ps1` — main PowerShell deployment script (implements Phases 1–4)  
- `VIConnect.ps1` — shared vCenter connection library used by this kit (and other scripts) to centralize and support plain password, SecretStore/VISecret, and legacy VICredentialStore connection modes.  
- `params/vm-settings_example.yaml` — example parameter file (copy and edit per VM)  
- `templates/original/*_template.yaml` — cloud-init `user-data`, `meta-data`, and `network-config` templates (copy to `templates/` and edit as needed)  
- `scripts/init-vm-cloudinit.sh` — script copied to the clone and run in Phase 2 to clear template artifacts and re-enable cloud-init on the clone  
- `infra/prevent-cloud-init.sh` — helper to install template infra files and create `/etc/cloud/cloud-init.disabled` on the template  
- `infra/cloud.cfg`, `infra/99-template-maint.cfg` — template-optimized cloud-init configuration files (only intentionally changed parameters are annotated in the shipped files)  
- `infra/enable-cloudinit-service.sh` — helper to ensure cloud-init services are enabled (rarely used)  
- `infra/req-pkg-cloudinit.txt`, `infra/req-pkg-cloudinit-full.txt` — recommended package lists for the template VM  
- `spool/` — repository includes a `spool/` directory (contains a dummy file so the folder exists after clone/unzip). At runtime the script creates `spool/<new_vm_name>/` for logs and generated files.

---

## 🛠️ Requirements / Pre-setup

### Admin host (PowerShell environment — Windows is the primary target):
- Windows PowerShell 5.1+ or PowerShell 7.5+ on Windows  
- VMware PowerCLI (e.g., VMware.VimAutomation.Core)  
- `powershell-yaml` module for YAML parsing  
- ISO creation tool: Win32 `mkisofs.exe` (the script defaults to a Win32 mkisofs from [**cdrtfe**](#-references)). Adjust `$mkisofs` and `$mkArgs` in the script if you use a different tool.  
- Clone or unzip this repository on the admin host. The repo contains a `spool/` directory (dummy file present), which the script expects to exist.

🔑 **vCenter credentials and PowerShell versions**

This kit uses a shared connection library (`VIConnect.ps1`) to support multiple credential modes and both Windows PowerShell 5.1+ and PowerShell 7.x on Windows. In all cases:

- `vcenter_host` and `vcenter_user` (since `cloudinit-linux-vm-deploy.ps1` v0.3.0) in `params/vm-settings_*.yaml` are **required**.  
- `vcenter_password` is **optional**; if it is blank or omitted, the script uses a credential store instead of a plain password.

At a high level, you can choose among:

- **Plain password mode**
  - Put `vcenter_password` directly in the parameter YAML.
  - The script connects with `Connect-VIServer -Password` using that value.
  - Easiest to get started with, but not recommended for long‑term production use because the password lives in clear text in YAML.

- **Modern SecretStore / VISecret mode (recommended for new setups)**
  - Leave `vcenter_password` empty or omit it in YAML.
  - Install and configure:
    - `Microsoft.PowerShell.SecretManagement`
    - `Microsoft.PowerShell.SecretStore`
    - [`VMware.VISecret`](#-references)
  - Typical flow:
    - Install the modules into a location that is visible from both Windows PowerShell 5.1 and PowerShell 7.x.  
      On current Windows, a common choice is the shared all‑users module path:
      - `"$env:ProgramFiles\WindowsPowerShell\Modules"`  
      (this path is normally part of `$env:PSMODULEPATH` in both 5.1 and 7.x).
    - In a PowerShell console, prepare a Vault (for example):
      ```
      Import-Module VMware.VISecret
      Initialize-VISecret -Vault "VMwareSecretStore"
      ```
    - Run this kit; in non‑plain mode, when there is no valid stored credential for `vcenter_user@vcenter_host`, the script will prompt once for the password on the first connection attempt of the run.  
      - Without `-UpdatePassword`, the password is used only for that run.  
      - With `-UpdatePassword`, the password is also saved or updated in the SecretVault after a successful connection.  
        Later runs can re‑use the stored secret without prompting, and you can explicitly refresh it by supplying `-UpdatePassword` again.

- **Legacy VICredentialStore mode**
  - Intended primarily for **Windows PowerShell 5.1 + classic PowerCLI** environments (for example on older Windows Server versions).
  - Enabled per‑run with the `-Legacy` switch, or by setting the global `$useLegacy = $true` near the top of `cloudinit-linux-vm-deploy.ps1`.
  - When `vcenter_password` is empty, the script uses the vSphere PowerCLI VICredentialStore cmdlets to read or update stored credentials:
    - `-UpdatePassword` and first-atempt prompt work in the same way as modern SecretStore mode.

In practice:

- SecretStore / VISecret works well with **PowerShell 7.x on current Windows Server / Windows 10+**, and can also be used from Windows PowerShell 5.1 if the modules are installed on a shared module path.  
- Legacy VICredentialStore is most predictable on **Windows PowerShell 5.1 with classic PowerCLI**; some newer combinations (for example PowerShell 7.x on recent Windows Server versions) may still work, but are not the primary target.

📝 This README does not attempt to be a full HOWTO for SecretManagement or VISecret; refer to the official documentation of those modules.

### Template VM (example: RHEL9):
- This kit assumes the template is a well-prepared VM that you have tailored as a base for cloning (this kit does not provide one).  
It may consist of considerable minimal resources, e.g., 2 CPUs, 2.1GB memory, 8GB primary disk, 2GB swap / 500MB kdump disks with 'Thin' vmdk format, all of which can be automatically expanded by the capabilities of cloud-init and the kit during provisioning.  
- `open-vm-tools` installed and running; required for guest operations such as `Copy-VMGuestFile` / `Invoke-VMScript` on the VMs cloned from this template (it should normally inherit working).  
- `cloud-init` and `cloud-utils-growpart` installed (optionally `dracut-config-generic` if you rebuild initramfs)  
- A CD/DVD device configured on the VM (seed ISO must be attached to the guest's CD drive)  
- Copy `infra/` to the template and run `prevent-cloud-init.sh` as root to install infra files and create `/etc/cloud/cloud-init.disabled`  
- Provide valid guest credentials for in‑guest operations: Define at least one user in the parameter file (typically as `user1`) and mark the intended account with `primary: true`. The selected primary user’s credentials are used for in‑guest actions such as `Invoke-VMScript` and other guest API calls. The account must be a real, local-login-capable administrative user on the Template VM (able to log in via the VM console) and must be able to run `sudo /bin/bash` without an interactive password prompt (for example via an appropriate `NOPASSWD:` sudoers rule).  
  - In normal mode, `userN.password` is the final deployed password and `userN.password_hash` is the final deployed password hash. Optionally, the primary user may define `userN.operation_password` as a separate initial guest-operation password already valid on the template VM. If `operation_password` is omitted for the primary user, the script falls back to `password`.
  - During normal-mode Phase‑3, the script prefers `operation_password` first and then `password`, and caches the credential that succeeds so guest operations can continue even after cloud-init changes the primary user's password.
  - `operation_password` is ignored for non-primary users and the script emits a warning if it is specified there.
👉 For a short checklist and examples of the parameter/template format, see [Caution: Parameter and template format changes](#%EF%B8%8F-caution-parameter-and-template-format-changes).

📝 **Notes and limitations:**
- Partition expansion: the partition(s) you intend to expand must be the last partition on the disk; otherwise the kit's non-LVM expansion helpers cannot extend them. For maximum flexibility, we recommend placing swap, kdump, and any other volumes that may need to be expanded (for example /opt or /u01) on separate, dedicated VMDKs.  
- Supported filesystems for kit-managed expansion: `ext2`, `ext3`, `ext4`, and `swap`. LVM-managed volumes are not supported.  
- Line endings: PowerShell scripts and `params/*.yaml` should use CRLF (Windows). Guest shell scripts and cloud-init templates must use LF (Unix).

---

## 🚀 Quick Start (short path)

1. Clone or unzip this repo on the Windows admin host and install PowerCLI and `powershell-yaml`.  
2. On the template VM:
   - Copy `infra/` into the template filesystem and run:
     ```sh
     cd infra
     sudo ./prevent-cloud-init.sh
     ```
     This installs the kit-optimized `/etc/cloud/cloud.cfg`, `/etc/cloud/cloud.cfg.d/99-template-maint.cfg`, and `/etc/cloud/cloud-init.disabled`.  
   - Shut down the VM and convert it to a vSphere Template.
3. On the admin host:
   - Copy `params/vm-settings_example.yaml` to a new filename (e.g., `params/vm-settings_myvm01.yaml`) and edit it.  
     💡**Tip:** include the target VM name (`new_vm_name` in `params`) in the filename for clarity.  
   - Copy `templates/original/*_template.yaml` to `templates/` and update them as needed (especially network device names in `network-config_template.yaml`).
4. Run the deploy script from the repository root:
   ```powershell
   .\cloudinit-linux-vm-deploy.ps1 -Phase 1,2,3 -Config .\params\vm-settings_myvm01.yaml
   ```
   - You may run a single phase (e.g., `-Phase 1`) or a contiguous sequence (e.g., `-Phase 1,2,3`). Non-contiguous lists (e.g., `-Phase 1,3`) are rejected.  
   - The script may prompt when `-NoRestart` conflicts with a requested multi-phase run; follow the prompts.

5. Inspect `spool/<new_vm_name>/` for logs and generated artifacts. Primary log: `spool/<new_vm_name>/deploy-YYYYMMDD.log`. Seed files are under `spool/<new_vm_name>/cloudinit-seed/` and the seed ISO is `spool/<new_vm_name>/cloudinit-linux-seed.iso`.

👉 **Refer to the script's help for details:**
```powershell
Get-Help ./cloudinit-linux-vm-deploy.ps1 -Detailed
```

### 📌 Name resolution behavior on deployed VMs (observed on RHEL 9.6)

When this kit is used with RHEL 9.6 and its cloud-init packages, we observed the following **distribution‑specific** behavior:

- The effective resolver configuration is taken from `/etc/resolv.conf`, which is a regular file (not a symlink).
- Even if the original **Template VM** was in a state where NetworkManager would update `/etc/resolv.conf` when DNS settings were changed, the **first cloud-init run on the clone** can alter that behavior.
- On some RHEL 9.6 + cloud-init combinations, the first cloud-init run on the clone can install `/etc/NetworkManager/conf.d/99-cloud-init.conf` with:
  ```ini
  [main]
  dns=none
  ```
  In that case, NetworkManager no longer manages DNS and does not update `/etc/resolv.conf` when you change DNS settings in `nmtui`, GUI tools, or `nmcli`. Only the contents of `/etc/resolv.conf` affect name resolution.

This behavior is determined by the **OS distribution and its cloud-init/NetworkManager integration**, not by this kit’s PowerShell / shell scripts. For this reason, the default supported posture of the kit is:

- **DNS resolver settings should be managed directly via `/etc/resolv.conf` on the guest.**

If you prefer to have NetworkManager manage DNS on a deployed VM, you can opt in by adjusting `/etc/NetworkManager/conf.d/99-cloud-init.conf` as described in the Troubleshooting section; see [“NetworkManager DNS changes do not affect name resolution”](#-troubleshooting-common-cases).

---

## 🔁 Phases — What Does Each Step Perform?

❗**Important:** Phase selection must be a contiguous ascending list (single phase is allowed). Examples:
- Valid: `-Phase 1` or `-Phase 1,2,3`
- Invalid: `-Phase 1,3`

Phase 1–3 form the main deployment flow. Phase 4 is a post-processing/finalization step and is recommended to be run after confirming Phase-3 succeeded.

――――――――――――――――――――――――――――――――

### Phase 1 — Automatic cloning
**Purpose:**
- Create a new VM by cloning the VM Template and apply specified vSphere-level hardware settings (CPU, memory, disk sizes, disk storage format). This phase does not perform guest power-on or shutdown.

**High-level steps:**
1. Validate no VM name collision.  
2. Resolve resource pool / datastore / host / portgroup from parameters.  
3. Perform `New-VM` to clone the template.  
4. Apply CPU and memory settings (`Set-VM`).  
5. Resize virtual disks as specified in `params.disks` (via `Set-HardDisk`).

**Result:**
- A new VM object is created in vCenter (not yet powered on).

**Cautions / Notes:**
- Do not run if a VM with the same name already exists — the script will abort.  
- This kit is not intended to retrofit cloud-init onto arbitrary running VMs; use the template → clone path.
- For disk resizing to work, each 'name' property in `params.disks` must exactly match the VM's virtual disk Name as shown in vSphere (for example: "Hard disk 1"). If the name does not match, `Set-HardDisk` will not find the disk and resizing will fail.

――――――――――――――――――――――――――――――――

### Phase 2 — Guest initialization
**Purpose:**
- Run guest-side initialization to remove template protections and clear cloud-init residual state. The VM is left powered on when Phase 2 completes so administrators can log in for verification or adjustments.

**High-level steps:**
1. Power on the VM (the script respects `-NoRestart` semantics and will prompt if conflicts arise).  
2. Ensure a working directory on the guest and copy `scripts/init-vm-cloudinit.sh` to the VM.  
3. Execute the init script, which:
   - Cleans subscription-manager state (RHEL specific).  
   - Deletes existing NetworkManager Ethernet connection profiles (Ethernet only).  
   - Runs `cloud-init clean`.  
   - Truncates `/etc/machine-id`.  
   - Removes `/etc/cloud/cloud-init.disabled` and `/etc/cloud/cloud.cfg.d/99-template-maint.cfg`.  
   - Writes `/etc/cloud/cloud.cfg.d/99-override.cfg` with `preserve_hostname: false` and `manage_etc_hosts: false`.  
4. Remove the transfer script from the guest.

**Result:**
- The clone is prepared to accept cloud-init personalization; the VM remains powered on.

**Cautions / Notes:**
- The included `scripts/init-vm-cloudinit.sh` targets RHEL-like systems; verify and adapt it for other distributions.  
- Because the VM remains powered on after Phase 2, avoid rebooting it before attaching the seed ISO in Phase 3 (unless you intend to boot with the seed attached); an unexpected boot may trigger cloud-init without the intended seed.

――――――――――――――――――――――――――――――――

### Phase 3 — Cloud-init seed creation & personalization
**Purpose:**
- Render `user-data`, `meta-data`, and optional `network-config` from YAML templates and parameters, create a `cidata` ISO, upload it to the datastore, attach it to the VM CD drive, boot the VM, and wait for cloud-init to complete. The VM is left powered on when Phase 3 finishes.

**High-level steps:**
1. Shut down the VM (unless `-NoRestart` is requested and accepted) if it is not already powered off.  
2. Ensure a local seed working directory and render `user-data`, `meta-data`, and (if present) `network-config` from the templates, replacing placeholders from `params`. For `user-data`, the script may inject a kit-specific `runcmd` block to:
   - Run `resize2fs` on specified non-root partitions.  
   - Reinitialize and resize swap devices with careful UUID updates to `/etc/fstab`.  
   - Modify NetworkManager Ethernet connection profiles with `nmcli` (`ignore-auto-routes`, `ignore-auto-dns`, IPv6 disablement).  
3. Create a `cidata` ISO using `mkisofs` and place it in `spool/<new_vm_name>/`.  
4. Upload the ISO to the datastore path specified by `params.seed_iso_copy_store` and attach it to the VM's CD drive. The script will abort if an ISO with the same name already exists at the target path.  
5. Power on the VM and detect cloud-init activity:  
   - Run a `quick-check` script (one-shot) on the guest to detect early evidence that cloud-init activated after the ISO attach.  
   - If quick-check indicates possible activity, copy a `check-cloud-init` script and poll until it reports completion (or timeout). Temporary helper scripts are removed from the guest; local copies, too.

**Result:**
- cloud-init has applied the personalization and the VM is ready; VM remains powered on.

**Cautions / Notes:**
- `/etc/hosts` is completely overwritten by the template's entries. If you need extra static host records, add them to the `write_files > content` section of `templates/user-data_template.yaml` before running Phase 3.  
- If `/etc/cloud/cloud-init.disabled` exists on the guest, Phase 3 cannot apply the seed — the script checks for this file and aborts when it can be detected. If the VM is powered off at the start of Phase 3 the script cannot probe the file and will continue; in that case cloud‑init may not be applied in the run; manual intervention may be required.  
- If `-NoRestart` prevents the required pre-shutdown (and therefore the boot at the end of this phase), the clone will not automatically apply the cloud‑init personalization even though the seed ISO is attached. Phase 3 will emit a warning in that case; a manual reboot is required to apply the modification.  
- Re-running Phase 3 repeatedly without finalizing with Phase 4 can cause undesired side effects, for example repeated SSH host‑key regeneration and duplicated NetworkManager connection profiles. If you must retry Phase 3 after a partial failure, re-run **Phase 2** (guest initialization) first to mitigate negative effects; note that filesystem expansions already applied will not be reprocessed and user duplication will not occur. Always run Phase 4 once you are satisfied.

――――――――――――――――――――――――――――――――

### Phase 4 — Cleanup and finalization
**Purpose:**
- Detach the seed ISO, remove the ISO file from the datastore, and (by default) create `/etc/cloud/cloud-init.disabled` on the guest to prevent future automatic cloud-init runs. If `-NoCloudReset` is supplied, the script detaches and deletes the ISO but skips creating `/etc/cloud/cloud-init.disabled`.

**High-level steps:**
1. Detach the CD/DVD media from the VM.  
2. Remove the uploaded ISO file from the datastore (via the vmstore path).  
3. Unless `-NoCloudReset` is set, use guest operations to create `/etc/cloud/cloud-init.disabled` on the guest.

**Result:**
- The seed ISO is removed and cloud-init is disabled for future boots (unless skipped).

**Cautions / Notes:**
- Phase 4 does not attempt to power on the VM. If the VM is powered off or VMware Tools are not running, the script cannot create `/etc/cloud/cloud-init.disabled` and will exit with an error; run Phase 4 when the VM is powered on or use `-NoCloudReset` if you only need to remove the ISO.  
- If detaching media triggers a confirmation prompt in the vSphere UI (VMRC or vSphere Client), you may need to confirm manually for the operation to complete.

---

## 🏗️ Template Infra: What is Changed and Why

Files in `infra/` (`cloud.cfg`, `99-template-maint.cfg`) are tuned to make the template safe for cloning. The shipped `infra/cloud.cfg` is based on RHEL9 defaults; only intentionally changed parameters are annotated with `[CHANGED]`. Key intentional changes include:

- `users: []` — suppress automatic creation of the default cloud user (e.g., `cloud-user`) — [CHANGED]  
- `disable_root: false` — prevent cloud-init from creating `sshd_config.d/50-cloud-init.conf` file. This strategy assues the template VM has been properly configured `sshd_config` or `sshd_config.d/80-custom.cfg`, etc. (adjust per policy) — [CHANGED]  
- `preserve_hostname: true` — preserve the template hostname (clones receive `99-override.cfg` to set `preserve_hostname: false`) — [CHANGED]  
- Set 'frequecy' of many cloud-init modules to `once` / `once-per-instance` to avoid repeated execution on templates and clones — [CHANGED]  
- Removed package update/upgrade from cloud-final to avoid unintended package changes on the template and during clone personalization — [CHANGED]

📝**Notes:**
- SSH host key regeneration settings (e.g., `ssh_deletekeys`, `ssh_genkeytypes`) are left at the distro defaults and are not intentionally changed by this kit.

---

## 🔁 DiskOnly Reapply Mode

### Overview & Use Cases
The DiskOnly reapply mode, introduced in cloudinit-linux-vm-deploy.ps1 (v0.1.8), is an auxiliary flow that provides a convenient, low‑risk way to perform *only* disk expansion (partition, filesystem, and swap resizing) on VMs originally deployed with this kit via the full template → clone → initialization → personalization workflow.

- Typically, expanding partitions requires manually removing and recreating partitions, running `fsck` and `resize2fs`, reformatting swap and editing `/etc/fstab`, etc. If the partition being expanded is the root filesystem, the process often also requires booting the VM from rescue media to perform the work offline. **DiskOnly** leverages cloud-init to perform these operations safely and automatically at the appropriate boot time, reducing risk and allowing less‑experienced operators to perform the task reliably.
- This feature is an auxiliary path and does not replace the kit’s normal full-deploy workflow. It is not intended as a general-purpose configuration-change mechanism for arbitrary VMs, which may be missing required cloud-init components or the template-derived configuration under `/etc/cloud`.
- As with regular partition operations, only partitions that are at the end of the disk can be expanded.

### Design Considerations
DiskOnly mode is designed to suppress the usual cloud-init effects such as user creation and network changes, and to run only the cloud-init modules required for disk operations. To work correctly, the kit must include the appropriate parameter file, seed YAML, and scripts in the tree.
In this mode, cloud-init does not register or update final user passwords; the primary user's `operation_password` (or fallback `password`) is used only for guest operations performed by the script itself.

⚠️ **Important:**  
A reapply is triggered by a different cloud-init `instance_id` than the previous deployment. For DiskOnly mode, ensure the `instance_id` in your parameter file has never been used in any previous deployment (for example, append or replace a date suffix at least).  
Alternatively, you can clear the previous cloud-init *instance_id* along with cache data by running `cloud-init clean`, if this data is not critical in your environment.  
Conversely, except for the core disk-related parameters (`resize_fs`, `swaps`), other values such as `hostname` should remain the same as the current guest settings.

🚨 **Warning:**  
Always test in a non-production environment first (use VM snapshots). See the general operational cautions elsewhere in this README.

### Workflow
1. On vSphere, expand the target VMDK(s) of the VM. Disk expansion will not be triggered unless there is available space at the device level.

2. Copy the DiskOnly sample parameter file `params/original/vm-settings_reapply_diskonly_example.yaml` into `params/` and edit it for your environment. You may rename the file (for example `vm-settings_reapply_diskonly_myvm01.yaml`).  

   📌 Set the `instance_id` in your parameter file to a value that has never been used in any previous deployment fot this VM.

3. Run the kit in DiskOnly mode; this mode never requires Phase-1. Example:
   ```powershell
   .\cloudinit-linux-vm-deploy.ps1 -Config params/vm-settings_reapply_diskonly_myvm01.yaml -DiskOnly -Phase 2,3
   ```
   - Phase‑2 copies and executes `scripts/init-vm-cloudinit-diskonly.sh` on the guest. That script first creates an archive backup of existing `/etc/cloud*` and `/var/log/cloud*.log` under `/root/cloudinit-backup/`, removes `cloud-init.disabled` marker if present, and installs the DiskOnly-specific `cloud.cfg` and `cloud.cfg.d/99-override.cfg` (embedded in the script).
   - Phase‑3 generates a seed ISO from `user-data_diskonly_template.yaml` and `meta-data_template.yaml` and applies it; `growpart` and `resizefs` (and any `runcmd` for swap reinitialization) run under the DiskOnly configuration.

   - Check the VM state and logs as needed before proceeding to the next phase.

4. Detach the seed ISO and recreate `cloud-init.disalbled` marker to deactivate cloud-init by running Phase-4. Example:
   ```powershell
   .\cloudinit-linux-vm-deploy.ps1 -Config params/vm-settings_reapply_diskonly_myvm01.yaml -Phase 4
   ```
   Note: The `-DiskOnly` option has no effect in Phase 4 and can be omitted.

### DiskOnly-specific Files
- **`scripts/init-vm-cloudinit-diskonly.sh`** — DiskOnly preparation script executed on the guest by Phase‑2 (backs up existing cloud config, removes `cloud-init.disabled` marker, and installs the DiskOnly `cloud.cfg` and override config entries. The *cloud configs* tuned for DiskOnly operation is embedded in the script.
- **`templates/original/user-data_diskonly_template.yaml`** — DiskOnly user-data template; copy it into `templates/` prior to running Phase-3.
- **`params/vm-settings_reapply_diskonly_example.yaml`** — Example parameter file to copy and edit for your run.

---

## 💿 mkisofs & ISO Creation Notes

- The script's default `$mkisofs` points to a Win32 `mkisofs.exe` from the cdrtfe distribution. If you use a different ISO tool (for example `genisoimage` under WSL), update variables `$mkisofs` (global) and `$mkArgs` (Phase-3 local) in the script.  
- The ISO must be labeled `cidata` and include `user-data` and `meta-data` at its root (and optionally `network-config`) so cloud-init recognizes it.  
- Different mkisofs implementations accept different flags (Joliet, Rock Ridge, encoding). If ISO creation fails, verify the `$mkisofs` path and the `$mkArgs` used in the script.

---

## ✅ Operational Recommendations

- Phase selection: use contiguous sequences only. Single-phase runs are supported; non-contiguous lists are rejected.  
- Prefer running Phase 4 as a separate finalization step after confirming Phase 3 succeeded.  
- VMware Tools: ensure `open-vm-tools` is installed and enabled on the Template VM; because clones are made from the Template they will normally inherit working VMware Tools immediately after cloning, which allows the guest operations used in Phases 2–4 to run without additional setup in standard environments.
- Credentials: example `params/*.yaml` files contain plain-text passwords for convenience. Treat them as sensitive and use secure credential storage in production.  
- `spool` directory: the repository includes a `spool/` directory (dummy file present) so it exists after clone/unzip. The script creates `spool/<new_vm_name>/` and writes `deploy-YYYYMMDD.log`, generated seed files under `cloudinit-seed/`, and the seed ISO `cloudinit-linux-seed.iso` there.

---

## 🔧 Troubleshooting (common cases)

- **cloud-init did not run:**
  - Confirm `/etc/cloud/cloud-init.disabled` was removed on the clone (Phase 2 must have succeeded).  
  - Inspect `spool/<new_vm_name>/cloudinit-seed/` for the generated `user-data`, `meta-data`, and `network-config`, and check timestamps; also check `spool/<new_vm_name>/cloudinit-linux-seed.iso` (mount or extract to verify contents).  
  - Verify VMware Tools are running; without them `Copy-VMGuestFile` and `Invoke-VMScript` will fail.  
  - Check guest logs: `/var/log/cloud-init.log`, `/var/log/cloud-init-output.log`, and `/var/lib/cloud/instance/*`.

- **ISO creation / upload failure:**
  - `$mkisofs` not found or incompatible flags. Update `$mkisofs` and `$mkArgs` in the script.  
  - `seed_iso_copy_store` parameter malformed. Expected format: `[DATASTORE] path` (for example `[COMMSTORE01] cloudinit-iso/`). Trailing slash is optional.  
  - A file with the same ISO name already exists at the datastore path (common when re-running Phase 3). Remedy: run Phase 4 alone (use `-NoCloudReset` to avoid creating `/etc/cloud/cloud-init.disabled`) to remove the ISO, or delete it manually in vSphere.

- **Network configuration not applied:**
  - Verify `templates/network-config_template.yaml` placeholders and `params`:`netifN.netdev` values match the guest's actual interface names (e.g., `ens192`). Also check vSphere NIC ordering vs. guest device naming if your environment renumbers devices.

- **Disk resizing did not occur (VMDK / partition / filesystem not grown)**
  - Check that each `params.disks[].name` exactly matches the VM's virtual disk Name as shown in vSphere (for example: "Hard disk 1"). If the name does not match, `Set-HardDisk` cannot find the disk and resizing will fail.  
    **Quick verification (PowerCLI):**  
    `Get-HardDisk -VM <template-or-vm> | Select-Object Name, Filename, CapacityGB`  
    Confirm the Name values match your `params` and whether CapacityGB was actually changed.  
  - Ensure the partition you intend to grow is the last partition on that disk; this kit's non‑LVM helpers cannot expand non-last partitions.  
  - If the disk Name and partition placement are correct but the guest size is unchanged, check the admin-host log `spool/<new_vm_name>/deploy-YYYYMMDD.log` for `Set-HardDisk` messages and errors.  
  - For filesystem-level resizing, this kit supports ext2/3/4 and swap; XFS and LVM-managed volumes are not supported.

- **NetworkManager DNS changes do not affect name resolution**

  **Symptoms**

  On a Linux VM deployed with this kit, you change DNS servers in NetworkManager (for example with `nmtui`, a GUI configuration tool, or `nmcli`) and restart NetworkManager or reboot, but:

  - `/etc/resolv.conf` does **not** change, and  
  - actual name resolution continues to use the old DNS servers until you edit `/etc/resolv.conf` manually.

  **Cause (distribution / cloud-init behavior, not kit logic)**

  This behavior was observed on some RHEL 9.6 environments, and it may also appear with other distributions or release/cloud-init combinations.  
  In those environments, the first cloud-init run on the clone writes `/etc/NetworkManager/conf.d/99-cloud-init.conf`:

  ```ini
      [main]
      dns=none
  ```

  With `dns=none` in effect, NetworkManager is explicitly instructed **not** to manage DNS and leaves `/etc/resolv.conf` to other mechanisms or manual edits.  

  Even if the Template VM was originally configured such that NetworkManager updated `/etc/resolv.conf` when DNS was changed (for example via `nmtui`), this clone-time cloud-init behavior can switch the deployed VM into a “static `/etc/resolv.conf`” mode.

  This repository’s scripts and infra files do **not** create or modify this file; it is produced by the distribution‑provided cloud-init / NetworkManager integration. The kit also does not change `/etc/resolv.conf` itself.

  As a result, on such systems:

  - `/etc/resolv.conf` behaves as a static file by default.
  - Per‑connection DNS settings in NetworkManager do not change name resolution unless you reconfigure NetworkManager to manage DNS again.

  **Default kit behavior**

  To keep the implementation simple and robust across distributions, this kit:

  - Assumes **resolver settings are managed directly in `/etc/resolv.conf`** on deployed VMs.
  - Does not attempt to override the OS/cloud-init DNS policy or to adjust NetworkManager’s `[main] dns=` setting automatically.

  If this default is acceptable for your environment, continue to manage DNS by editing `/etc/resolv.conf` on the guest.

  **Opt-in: allow NetworkManager to manage DNS again**

  If you prefer NetworkManager‑driven DNS on a particular VM, you can adjust its policy manually:

  1. Check whether the cloud-init NetworkManager fragment exists:

     ```sh
     sudo ls -l /etc/NetworkManager/conf.d/99-cloud-init.conf
     ```

  2. If the file exists, choose **one** of the following:

     - **Delete the file** so that NetworkManager falls back to its default DNS behavior  
       (only do this if the file does not contain any other configuration you rely on):

       ```sh
       sudo rm /etc/NetworkManager/conf.d/99-cloud-init.conf
       ```

     - **Or** edit it and either:
       - change `dns=none` to `dns=default`, or
       - comment out or remove the `dns=` line entirely.

  3. Restart NetworkManager:

     ```sh
     sudo systemctl restart NetworkManager
     ```

  4. Change DNS servers for the relevant connection using your usual method (for example, `nmtui`, a GUI tool, or `nmcli`) and re‑apply the connection.

  5. Confirm that `/etc/resolv.conf` is now updated when you change DNS in NetworkManager:

     ```sh
     cat /etc/resolv.conf
     ```

  After these adjustments, `/etc/resolv.conf` should once again be managed by NetworkManager on that VM, and subsequent DNS changes through NetworkManager will be reflected in name resolution.

  > **Note:** This behavior (creation and contents of `99-cloud-init.conf`, and the fact that `/etc/resolv.conf` is a regular file) was observed with the RHEL 9.6 + cloud-init packages used while developing this kit. Other RHEL releases or other distributions may behave differently. In some environments, you may also have to control whether `/etc/resolv.conf` is a symbolic link (for example to `/run/systemd/resolve/stub-resolv.conf` or `/run/NetworkManager/resolv.conf`).

---

## 🧾 Logs & Debugging

- Logs and generated artifacts are written to `spool/<new_vm_name>/` on the admin host. The primary log is `spool/<new_vm_name>/deploy-YYYYMMDD.log`. Seed YAMLs are under `spool/<new_vm_name>/cloudinit-seed/` and the ISO is `spool/<new_vm_name>/cloudinit-linux-seed.iso`.  
- Run the script with `-Verbose` to print additional internal steps to the console for debugging.

---

## 🔗 References

- [cloud-init documentation](https://cloud-init.io/)
- [VMware PowerCLI](https://developer.vmware.com/powercli)
- [powershell-yaml](https://github.com/cloudbase/powershell-yaml)
- [cdrtfe (mkisofs win32)](https://sourceforge.net/projects/cdrtfe/)
- [PowerCLI-Example-Scripts (VMware.VISecret)](https://github.com/vmware-archive/PowerCLI-Example-Scripts)

---

## 📜 License

This project is licensed under the MIT License — see the repository [LICENSE](LICENSE) file for details.
