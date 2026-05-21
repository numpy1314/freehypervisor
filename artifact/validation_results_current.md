# HHAL Validation Results

## Host Information

- Date: 2026-05-19
- Hostname: `bullet1517-imini-Pro`
- Architecture: x86_64
- `/dev/kvm` present: yes
- User in `kvm` group: no
- Run mode: via `sudo`

## Build Information

- Build entry: `bash artifact/build_kvm_host_artifacts.sh`
- Generated binaries:
  - `/tmp/hhal_linux_smoke_test`
  - `/tmp/hhal_linux_extended_state_test`
  - `/tmp/hhal_linux_irq_routing_test`
  - `/tmp/hhal_linux_irq_delivery_guest`
  - `/tmp/hhal_linux_signal_mask_test`
  - `/tmp/hhal_linux_minimal_guest`

## Smoke Test Run

### Command

```bash
sudo /tmp/hhal_linux_smoke_test
```

### Result

- Exit status: success
- Assessment: pass

### Output

```text
HHAL API version query succeeded: 12
VM create succeeded
VCPU create succeeded
REGS round-trip succeeded
SREGS round-trip succeeded
MP state round-trip succeeded
HHAL Linux smoke test completed successfully
```

## Minimal Guest Demo Run

### Command

```bash
sudo /tmp/hhal_linux_minimal_guest
```

### Result

- Exit status: success
- Assessment: pass

### Output

```text
Minimal HHAL guest reached HLT successfully
```

## Interpretation

- The smoke test provides the first real host-side evidence that:
  - `/dev/kvm` can be opened
  - VM/VCPU lifecycle works
  - implemented `REGS/SREGS/MP` state transport works on a real KVM host
- The minimal guest demo now provides the first real host-side evidence that:
  - guest memory registration works
  - minimal x86 VCPU state initialization works well enough for guest entry
  - one `KVM_RUN` reaches guest code and exits cleanly through `HLT`
- The extended state test now provides real host-side evidence that:
  - `FPU` state round-trip works
  - `LAPIC` state round-trip works
  - `EVENTS` state round-trip works
  - `DEBUG` state round-trip works
  - `XSAVE` state round-trip works
  - `XCRS` state round-trip works

## Follow-up

- Host-side validation now confirms both:
  - smoke test pass
  - minimal guest demo pass
- extended state test pass
- The earlier failures and fixes were:
  - page-aligned guest backing memory
  - preserving host-provided initial `REGS/SREGS` and patching minimally
- Extended state validation was started on host:
- Extended state validation history on host:
  - `FPU` succeeded immediately
  - `LAPIC` initially failed
  - diagnosing that failure exposed x86/KVM ordering constraints:
    - `KVM_GET_LAPIC` requires irqchip support
    - `KVM_CREATE_IRQCHIP` requires prior `KVM_SET_TSS_ADDR`
    - `KVM_CREATE_IRQCHIP` also needed to occur before VCPU creation in this test flow
- After updating the test sequence to:
  - create VM
  - set TSS address
  - create irqchip
  - create VCPU
  all four extended state families passed.
- Next action: continue backend feature coverage or prepare a cleaner final artifact overview

## IRQ Routing Test Run

### Command

```bash
sudo /tmp/hhal_linux_irq_routing_test
```

### Result

- Exit status: success
- Assessment: pass

### Output

```text
IRQCHIP route install succeeded: gsi=0 -> IOAPIC pin 0
MSI route install succeeded: gsi=1 -> addr=0xfee00000 data=0x20
IRQ line assert/deassert succeeded on routed GSI 0
HHAL Linux IRQ routing test completed successfully
```

## Updated Interpretation

- The IRQ routing test now provides real host-side evidence that:
  - `hhal_vm_create_irqchip()` works with the validated x86/KVM ordering
  - `hhal_vm_set_irq_routing()` succeeds for both:
    - `HHAL_IRQ_ROUTE_IRQCHIP`
    - `HHAL_IRQ_ROUTE_MSI`
  - `hhal_vm_irq_line()` can drive a routed GSI through assert/deassert

## Signal Mask Test Run

### Command

```bash
sudo /tmp/hhal_linux_signal_mask_test
```

### Result

- Exit status: failed on first host attempt
- Assessment: payload size mismatch diagnosed

### First Output

```text
set signal mask via state blob failed: HHAL_ERR_INVALID (-2)
```

### Diagnosis

- the initial implementation used a two-word signal-mask payload
- on this validated x86_64 KVM host, `KVM_SET_SIGNAL_MASK` rejected that payload with `EINVAL`
- the backend has been tightened to the one-word payload that matches the observed host behavior

## Guest IRQ Delivery Run

### Command

```bash
sudo /tmp/hhal_linux_irq_delivery_guest
```

### Result

- Exit status: success
- Assessment: pass

### Output

```text
Guest interrupt handler executed successfully via routed IRQ0
```

## Signal Mask Test Run

### Result

- Exit status: success
- Assessment: pass

### Output

```text
SIGNAL_MASK state write succeeded
Direct signal mask write succeeded
HHAL Linux signal mask test completed successfully
```
