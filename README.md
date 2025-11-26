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

### ⚠️ Caution: Parameter and template format changes

Recent changes introduced updates to parameter and seed-template formats (multi-user support, per-user SSH key placement, DNS nameserver handling, and a consolidated swaps mapping). Before applying these changes in an environment, validate the generated seed files:

- Run the script with Phase 3 only and with `-NoRestart` to produce the seed files without reapplying personalization to a VM:
  ```powershell
  .\cloudinit-linux-vm-deploy.ps1 -Phase 3 -Config .\params\<your_params>.yaml -NoRestart
  ```
- Inspect `spool/<new_vm_name>/cloudinit-seed/` `user-data` and `network-config` to confirm formatting and indentation.

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
This kit is designed for the template → clone → initialization → personalization flow. It is not intended to retrofit cloud-init onto arbitrary, already-running production VMs (at the time being).

---

## 📁 Key Files

- `cloudinit-linux-vm-deploy.ps1` — main PowerShell deployment script (implements Phases 1–4)  
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
- Windows PowerShell (5.1+) or PowerShell Core on Windows  
- VMware PowerCLI (e.g., VMware.VimAutomation.Core)  
- `powershell-yaml` module for YAML parsing  
- ISO creation tool: Win32 `mkisofs.exe` (the script defaults to a Win32 mkisofs from cdrtfe). Adjust `$mkisofs` and `$mkArgs` in the script if you use a different tool.  
- Clone or unzip this repository on the admin host. The repo contains a `spool/` directory (dummy file present), which the script expects to exist.

### Template VM (example: RHEL9):
- This kit assumes the template is a well-prepared VM that you have tailored as a base for cloning (this kit does not provide one).  
It may consist of considerable minimal resources, e.g., 2 CPUs, 2.1GB memory, 8GB primary disk, 2GB swap / 500MB kdump disks with 'Thin' vmdk format, all of which can be automatically expanded by the capabilities of cloud-init and the kit during provisioning.  
- `open-vm-tools` installed and running; required for guest operations such as `Copy-VMGuestFile` / `Invoke-VMScript` on the VMs cloned from this template (it should normally inherit working).  
- `cloud-init` and `cloud-utils-growpart` installed (optionally `dracut-config-generic` if you rebuild initramfs)  
- A CD/DVD device configured on the VM (seed ISO must be attached to the guest's CD drive)  
- Copy `infra/` to the template and run `prevent-cloud-init.sh` as root to install infra files and create `/etc/cloud/cloud-init.disabled`  
- Provide valid guest credentials for in‑guest operations: Define at least one user in the parameter file (typically as `user1`) and mark the intended account with `primary: true`. The selected primary user’s credentials are used for in‑guest actions such as `Invoke-VMScript` and other guest API calls. The account must be a real, local-login-capable administrative user on the Template VM (able to log in via the VM console) and must be able to run `sudo /bin/bash` without an interactive password prompt (for example via an appropriate `NOPASSWD:` sudoers rule).  
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

---

## 📜 License

This project is licensed under the MIT License — see the repository [LICENSE](LICENSE) file for details.
