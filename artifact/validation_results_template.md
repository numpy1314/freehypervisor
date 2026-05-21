# HHAL Validation Results Template

## Purpose

This file is a fill-in template for recording real host-side validation results.

Use it after running:

- `artifact/hhal_linux_smoke_test.c`
- `artifact/hhal_linux_minimal_guest.c`

on a machine with `/dev/kvm`.

## Host Information

- Date:
- Hostname:
- CPU model:
- Architecture:
- Kernel version:
- Distribution:
- `/dev/kvm` present:
- User in `kvm` group:
- KVM modules loaded:

## Build Information

- Compiler:
- Compiler version:
- Build command for smoke test:
- Build command for minimal guest demo:
- Git commit or working snapshot identifier:

## Smoke Test Run

### Command

```bash
/tmp/hhal_linux_smoke_test
```

### Exit Code

```text
<fill here>
```

### Output

```text
<fill here>
```

### Assessment

- Pass / Fail:
- Notes:

## Minimal Guest Demo Run

### Command

```bash
/tmp/hhal_linux_minimal_guest
```

### Exit Code

```text
<fill here>
```

### Output

```text
<fill here>
```

### Assessment

- Pass / Fail:
- Notes:

## Observed Issues

- Issue 1:
- Issue 2:

## Interpretation

- Does smoke test validate VM/VCPU lifecycle?
- Does minimal guest demo reach `HHAL_EXIT_HLT`?
- Did CPUID helper path succeed or fall back?
- Are there host-specific quirks worth recording?

## Final Summary

- Overall validation status:
- Confidence level:
- Recommended next action:
