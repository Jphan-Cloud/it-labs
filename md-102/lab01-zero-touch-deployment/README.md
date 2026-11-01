# Lab 01 – Zero-Touch Windows Deployment with Autopilot, Intune & Conditional Access

![Status](https://img.shields.io/badge/status-in%20progress-yellow) ![Platform](https://img.shields.io/badge/platform-Windows%2011-blue) ![Intune](https://img.shields.io/badge/Microsoft-Intune-0078D4)

## Business Scenario

A company is hiring remote employees and wants laptops shipped straight from the vendor to the new hire's home. IT should never have to image, touch, or hand-configure the device. When the employee powers it on and signs in with their work account, the device must:

1. Join Microsoft Entra ID and enroll in Intune automatically
2. Receive company apps and security settings before the user reaches the desktop
3. Encrypt the drive and back up the recovery key
4. Rotate the local admin password automatically
5. Be **blocked from company data** if it ever falls out of compliance

This lab builds that end-to-end on a physical device.

---

## Architecture

```mermaid
flowchart LR
    A[New device<br/>powered on] --> B[OOBE: user signs in<br/>with work account]
    B --> C{Autopilot<br/>profile found?}
    C -- Yes --> D[Entra ID join +<br/>Intune enrollment]
    D --> E[Enrollment Status Page<br/>apps + policies install]
    E --> F[Desktop ready]
    F --> G{Compliant?}
    G -- Yes --> H[✅ Access to<br/>Microsoft 365]
    G -- No --> I[⛔ Blocked by<br/>Conditional Access]
```

| Component | Purpose in this lab |
|-----------|--------------------|
| Windows Autopilot | Recognizes the device by hardware hash and applies the deployment profile at OOBE |
| Microsoft Entra ID | Device identity (Entra join), users, groups, Conditional Access |
| Microsoft Intune | Enrollment, configuration, compliance, app deployment |
| Enrollment Status Page (ESP) | Holds the user at setup until required apps and policies are applied |
| BitLocker | Full-disk encryption with recovery key escrowed to Entra ID |
| Windows LAPS | Unique, rotating local admin password stored in Entra ID |
| Conditional Access | Requires a compliant device to access Microsoft 365 |

---

## Environment

| Item | Details |
|------|---------|
| Tenant | Microsoft 365 Business Premium trial (includes Intune + Entra ID P1) |
| Device | Lenovo ThinkCentre M70q, Windows 11 Pro, TPM 2.0, UEFI + Secure Boot |
| Test users | `lab.user1`, `lab.user2` (licensed), `breakglass-admin` (excluded from CA) |
| Admin tools | Intune admin center, Entra admin center, PowerShell 5.1 |

---

## Build Steps

### Phase 1 – Tenant Preparation

| Step | Where | Configuration |
|------|-------|---------------|
| 1.1 | Entra admin center → Users | Create test users and assign Business Premium licenses |
| 1.2 | Entra → Users | Create a **break-glass** Global Admin account, excluded from all CA policies |
| 1.3 | Entra → Properties → Security defaults | **Disable** security defaults (required before Conditional Access can be used) |
| 1.4 | Intune → Devices → Enrollment → Windows → Automatic Enrollment | Set **MDM user scope** to *All* (or a pilot group) |
| 1.5 | Entra → Devices → Device settings | Confirm users may join devices to Entra ID, and enable **Microsoft Entra Local Administrator Password Solution (LAPS)** |
| 1.6 | Intune → Tenant administration → Customization | Add company name, logo, and support contact (shown during OOBE) |

📸 *Screenshot: Automatic Enrollment MDM user scope*

### Phase 2 – Dynamic Device Group

Create a group that automatically contains every Autopilot-registered device.

- **Entra → Groups → New group**
- Type: Security · Membership: **Dynamic Device**
- Name: `SG-Autopilot-Devices`
- Rule:

```text
(device.devicePhysicalIDs -any (_ -contains "[ZTDId]"))
```

> `ZTDId` is the tag Autopilot stamps on every registered device. Any device imported into Autopilot joins this group automatically, so all profiles and policies target it without manual assignment.

📸 *Screenshot: dynamic membership rule*

### Phase 3 – Register the Device in Autopilot

On the M70q at the first OOBE screen, press **Shift + F10** to open a command prompt and run:

```powershell
powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Install-Script -Name Get-WindowsAutopilotInfo -Force
Get-WindowsAutopilotInfo -Online -GroupTag "LAB"
```

Sign in with an Intune admin account when prompted. The script uploads the hardware hash directly, so **no CSV ever leaves the device**.

Verify in **Intune → Devices → Enrollment → Windows → Devices (Autopilot)**. The serial number should appear within ~15 minutes.

> **Note:** Windows Autopilot *device preparation* is a newer option that skips hardware hash registration. This lab uses classic user-driven Autopilot because it remains heavily tested on MD-102 and is still the standard in most enterprises.

📸 *Screenshot: device listed in Autopilot devices (serial blurred)*

### Phase 4 – Autopilot Deployment Profile

**Intune → Devices → Enrollment → Windows → Deployment profiles → Create profile (Windows PC)**

| Setting | Value | Why |
|---------|-------|-----|
| Convert all targeted devices to Autopilot | No | Not needed for new devices |
| Deployment mode | User-driven | User signs in with their own account |
| Join to Entra ID as | Microsoft Entra joined | Cloud-only, no on-prem AD dependency |
| Microsoft Software License Terms | Hide | Fewer clicks for the user |
| Privacy settings | Hide | Defaults applied by policy |
| Hide change account options | Hide | Prevents personal-account setup |
| User account type | **Standard** | User does not get local admin |
| Apply device name template | Yes → `LAB-%SERIAL%` | Consistent naming (15-character max) |
| Assignment | `SG-Autopilot-Devices` | |

📸 *Screenshot: profile summary and "Assigned" profile status on the device*

### Phase 5 – Enrollment Status Page

**Intune → Devices → Enrollment → Windows → Enrollment Status Page → Create**

| Setting | Value |
|---------|-------|
| Show app and profile configuration progress | Yes |
| Show error when installation takes longer than | 60 minutes |
| Block device use until all apps and profiles are installed | Yes → selected apps only |
| Required apps | Microsoft 365 Apps, 7-Zip (Win32) |
| Assignment | `SG-Autopilot-Devices` |

### Phase 6 – Security Configuration

**BitLocker:** Endpoint security → Disk encryption → Create policy → Windows → BitLocker

| Setting | Value |
|---------|-------|
| Require device encryption | Enabled |
| Allow warning for other disk encryption | Disabled (enables silent encryption) |
| Allow standard user encryption | Enabled |
| OS drive recovery: save recovery info to Entra ID | Enabled, and require backup before encryption |

**Windows LAPS:** Endpoint security → Account protection → Create policy → Local admin password solution

| Setting | Value |
|---------|-------|
| Backup directory | Backup to Microsoft Entra ID only |
| Password age (days) | 30 |
| Password complexity | Large + small letters + numbers + special characters |
| Post-authentication actions | Reset password and log off |

📸 *Screenshot: both policies assigned to `SG-Autopilot-Devices`*

### Phase 7 – Applications

**Microsoft 365 Apps:** Apps → Windows → Add → Microsoft 365 Apps (Windows 10 and later). Required assignment.

**7-Zip as a Win32 app** (demonstrates custom packaging):

```powershell
# Package the MSI with the Microsoft Win32 Content Prep Tool
.\IntuneWinAppUtil.exe -c .\source -s 7z-x64.msi -o .\output
```

| Field | Value |
|-------|-------|
| Install command | `msiexec /i "7z-x64.msi" /qn` |
| Uninstall command | `msiexec /x {ProductCode} /qn` |
| Install behavior | System |
| Detection rule | MSI product code (auto-detected) |
| Assignment | Required → `SG-Autopilot-Devices` |

> `.intunewin` output files are excluded from the repo by `.gitignore`.

### Phase 8 – Compliance Policy

**Devices → Compliance → Create policy → Windows 10 and later**

| Category | Setting | Value |
|----------|---------|-------|
| Device Health | Require BitLocker | Require |
| Device Health | Require Secure Boot | Require |
| Device Properties | Minimum OS version | Current supported build |
| System Security | Firewall | Require |
| System Security | Microsoft Defender Antimalware | Require |
| System Security | Real-time protection | Require |
| Actions | Mark device noncompliant | Immediately (0 days) |

Assign to `SG-Autopilot-Devices`.

### Phase 9 – Conditional Access

**Entra → Protection → Conditional Access → New policy**

| Setting | Value |
|---------|-------|
| Name | `CA01 - Require compliant device for M365` |
| Users | Include: test users group · **Exclude: break-glass account** |
| Target resources | Office 365 |
| Conditions → Device platforms | Windows |
| Grant | **Require device to be marked as compliant** |
| Enable policy | **Report-only** first, then **On** after verification |

> Starting in Report-only confirms the impact in sign-in logs before enforcing, the same change-management approach used in production.

📸 *Screenshot: CA policy summary*

---

## Deployment & Verification

1. Reset the M70q to OOBE (**Settings → System → Recovery → Reset this PC → Remove everything**), or boot from fresh Windows 11 media
2. Connect to the network and sign in as `lab.user1`
3. Watch the company branding and ESP progress screens

| Check | How | Expected result |
|-------|-----|-----------------|
| Entra join | `dsregcmd /status` | `AzureAdJoined : YES` |
| Intune enrollment | Intune → Devices → Windows | Device listed as `LAB-<serial>`, user `lab.user1` |
| Device name | Settings → System → About | Matches template |
| Standard user | `net localgroup administrators` | `lab.user1` **not** listed |
| Apps | Start menu | Microsoft 365 Apps + 7-Zip installed |
| BitLocker | `manage-bde -status C:` | Protection On, XTS-AES |
| Recovery key escrow | Intune → device → Recovery keys | Key present |
| LAPS | Intune → device → Local admin password | Password retrievable, rotation date shown |
| Compliance | Intune → device → Device compliance | **Compliant** |
| CA (Report-only) | Entra → Sign-in logs → Report-only tab | "Report-only: Success" |

A verification script that checks most of these from the device is in [`../../practice/Test-DeviceReadiness.ps1`](../../practice/Test-DeviceReadiness.ps1).

### Proving Conditional Access Works

1. Switch the CA policy from Report-only to **On**
2. Temporarily edit the compliance policy so the **minimum OS version** is higher than the device's build
3. Sync the device (Settings → Accounts → Access work or school → Info → Sync)
4. Device shows **Not compliant**, and opening Outlook or office.com is **blocked** with a "device must be compliant" message
5. Revert the minimum OS version, sync again, and access is restored

📸 *Screenshots: noncompliant status, CA block page, sign-in log showing "Failure" with policy CA01*

---

## Issues & Fixes

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | | | |
| 2 | | | |

<details>
<summary>Common issues reference</summary>

| Symptom | Likely cause |
|---------|-------------|
| Device doesn't get Autopilot profile at OOBE | Profile not yet assigned (check "Profile status" on the Autopilot device); dynamic group membership still processing |
| "Something went wrong" / 80180018 during enrollment | User not licensed for Intune, or MDM user scope doesn't include the user |
| ESP stuck on apps | Win32 detection rule wrong, so Intune keeps thinking install failed |
| BitLocker not encrypting silently | "Allow warning for other disk encryption" not disabled, or no TPM |
| CA policy can't be created | Security defaults still enabled |
| Device noncompliant right after enrollment | Compliance not yet evaluated; sync and wait before testing |

</details>

---

## Cleanup

- Delete the device from **Intune → Devices**, then from **Autopilot devices** (Intune record must go first)
- Delete the Entra device object
- Set CA policy to **Off** or delete it
- Remove test users or let the trial expire

---

## Skills Demonstrated

- Windows Autopilot user-driven deployment and hardware hash registration
- Intune enrollment, dynamic groups, and policy targeting
- Win32 app packaging and detection rules
- Endpoint security: BitLocker, Windows LAPS, compliance policies
- Conditional Access design with break-glass exclusion and report-only rollout
- Verification and troubleshooting with `dsregcmd`, `manage-bde`, and Intune diagnostics
