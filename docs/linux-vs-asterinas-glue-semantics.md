# Linux vs Asterinas AxVisor Host Glue Semantics

This note is a discussion baseline before further Linux-host fixes.  It
separates "the interface is wired" from "the Linux implementation provides the
same semantics as the working Asterinas host glue".

## Scope

Current evidence is taken from:

- Asterinas host glue:
  `ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs`
- Linux Rust API bridge:
  `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_linux_bridge/src/lib.rs`
- Linux Rust adapter:
  `linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_main.rs`
- Linux C shim:
  `linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_shim.c`
- AxVisor RISC-V IRQ injection:
  `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_core/src/arch/riscv64.rs`

## Summary

The Linux side is not simply missing one AxVisor API function.  Most public
AxVisor API traits are wired, but some implementations do not naturally match
the bare-metal/unikernel-style semantics that Asterinas exposes to AxVisor.

For Linux guests, the high-risk gaps are:

1. host physical address to kernel virtual address translation;
2. guest RAM backing and DMA-visible host physical addresses;
3. external IRQ injection context;
4. host ownership of passthrough MMIO devices;
5. host FDT discovery and passthrough IRQ/address parsing.

## Interface Matrix

| Interface area | Asterinas semantics | Linux current semantics | Equivalent? | Linux guest risk |
| --- | --- | --- | --- | --- |
| `HostIf::get_host_cpu_num` / `init_percpu` | Direct OSTD CPU/percpu calls. | FFI into Linux adapter plus `ax_percpu` setup. | Mostly yes. | Low. |
| `HostIf::release_host_filesystems` | Not present in the Asterinas glue shown here. The working Asterinas path does not need to unbind Linux platform drivers. | Implemented as a Linux-specific resource release hook that unbinds platform MMIO devices before guest passthrough ownership. | No. This is a Linux-specific semantic extension. | High. If virtio-mmio or serial remains host-owned, guest passthrough is unsafe or nonfunctional. |
| `ConsoleIf` | Writes to Asterinas console devices or early print fallback. | FFI into Linux console/shell buffers. | Functionally close. | Low. Messy dmesg output is not the main Linux guest blocker. |
| `TimeIf` | Asterinas monotonic clock and architecture timer hook. | FFI into Linux timer adapter. | Needs runtime verification. | Medium. Bad timer semantics can stall guest scheduling and timeouts. |
| `SyncIf` | Native Asterinas `WaitQueue`. | Linux `CondVar` plus ticket accounting and destroyed-state checks. | Mostly yes, but more complex. | Medium-low. Bugs would affect vCPU startup/wakeup. |
| `TaskIf` | Asterinas kernel task with CPU affinity and task registry. | Linux kthread, cpumask, task registry, and completion tracking. | Mostly yes. | Medium. Current-vCPU context depends on correct task identity. |
| `IrqIf` | For RISC-V S external IRQ, directly iterates pending external interrupts and calls `inject_current_interrupt(irq_id)`. | Claims host PLIC IRQs, queues events, drains them, then injects through the core bridge. | No. The path shape differs materially. | High. `inject_current_interrupt` requires current vCPU context. Calling it from a non-vCPU Linux IRQ context can fail. |
| `MemoryIf::alloc/dealloc` | OSTD frame/segment allocator; allocated frames are naturally accessible through linear mapping. | Linux page allocator with explicit allocation records. | Partly. | Medium. Contiguous/aligned allocations and release accounting must match AxVisor assumptions. |
| `MemoryIf::phys_to_virt` / `virt_to_phys` | Simple host linear mapping: `paddr_to_vaddr` and reverse linear translation. | Allocation records first, then special MMIO/PLIC mapping, then `memremap` fallback for reserved/no-map ranges; reverse path relies on records or `virt_addr_valid`. | No. This is the largest semantic mismatch. | Very high. Page tables, guest image loading, FDT access, guest RAM, and virtio DMA paths depend on this. |
| `ArchIf::host_fdt_paddr` | Provided by the Asterinas arch boot path. | Linux loadable module cannot directly use `initial_boot_params_pa`; current path uses `host_fdt_path` or explicit paddr injection. | No. | High. Passthrough address and IRQ discovery depends on the host DTB being correct and accessible. |
| `FsIf` | Not implemented by the Asterinas glue shown here. | Implemented through Linux VFS: open, read, metadata, readdir, current dir. | Linux-only capability. | Medium. Image reads work only if destination buffers are translated correctly, especially guest reserved RAM. |

## High-Risk Semantic Differences

### 1. `MemoryIf::phys_to_virt`

Asterinas exposes a broad linear mapping assumption:

- `phys_to_virt(addr)` calls `paddr_to_vaddr(addr)`.
- `virt_to_phys(addr)` calls the reverse linear mapping helper.

Linux cannot use that assumption for all addresses:

- ordinary adapter allocations can be translated by allocation records;
- guest RAM may be a `reserved-memory/no-map` host physical range and needs
  `memremap`;
- passthrough MMIO and PLIC registers need `ioremap`;
- arbitrary `__va()`-style translation is not valid for no-map or MMIO ranges.

Decision needed: define the exact address classes that Linux
`MemoryIf::phys_to_virt` must support, and define mapping lifetime for each
class.

Proposed classes:

| Class | Example | Required mapping | Lifetime question |
| --- | --- | --- | --- |
| adapter-owned frames | page table frames, internal buffers | allocation record VA | until dealloc |
| contiguous adapter allocations | VM page tables or buffers | allocation record VA | until dealloc |
| guest reserved RAM | `0x9000_0000..0x9400_0000` in current RISC-V config | `memremap` with RAM attributes | per page/chunk or whole region |
| passthrough MMIO | serial, virtio-mmio | `ioremap` with device attributes | until VM teardown or module unload |
| host PLIC MMIO | claim/complete register | `ioremap` with device attributes | can be cached |

### 2. Guest RAM Backing and DMA Visibility

The working Asterinas Linux guest config uses identical mapping for guest RAM:

```toml
memory_regions = [
  [0x9000_0000, 0x0400_0000, 0x7, 1],
]
```

That means guest GPA equals host PA.  This matters for passthrough virtio-mmio:
the QEMU device performs DMA to host physical addresses, not to an arbitrary
AxVisor-internal allocation.

Linux currently tries to create this condition by injecting a
`reserved-memory/no-map` node into the host DTB used to boot Linux, then using
the same physical range as guest RAM.

Decision needed: confirm whether Linux guest support requires:

- guest RAM must be `MapIdentical`;
- the range must be reserved from the Linux host at boot;
- the range must be excluded from Linux normal memory management;
- AxVisor must still be able to access the range through `memremap`.

### 3. External IRQ Injection Context

Asterinas handles RISC-V S external IRQ like this:

1. detect S external vector;
2. iterate pending external interrupts;
3. call `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`.

Linux handles it through a queue:

1. detect external vector;
2. claim passthrough IRQ from host PLIC;
3. push `ExternalIrqEvent`;
4. drain pending events;
5. call into the AxVisor core bridge.

The core function `inject_current_interrupt` calls
`try_current_vcpu_context()`.  If the Linux drain/inject path runs outside the
vCPU thread context, injection can return `false` even though the host PLIC IRQ
was claimed.

Decision needed:

- Should Linux external IRQ delivery inject by explicit `vm_id` instead of
  relying on current vCPU context?
- Or should the Linux IRQ path only enqueue and wake the relevant vCPU thread,
  with injection performed inside the vCPU run loop?
- How should PLIC completion be delayed until the guest has consumed the
  virtual interrupt?

### 4. Host Passthrough Device Ownership

Asterinas does not need to unbind Linux platform drivers.  Linux does.

Current Linux shim maps `HostIf::release_host_filesystems` onto platform MMIO
driver release:

- find a platform device by MMIO base;
- if a driver is bound, call `device_release_driver(dev)`;
- use registered passthrough devices and `release_mmio_paddrs`.

This function name is inherited from the storage handoff idea, but its actual
Linux responsibility is broader: release host ownership of passthrough MMIO
devices.

Decision needed:

- Keep using `release_host_filesystems` as the hook and document the broader
  Linux semantics;
- or introduce/rename a clearer host resource release hook later.

### 5. Host FDT Availability

Asterinas arch code exposes the boot FDT paddr through `host_fdt_paddr()`.

Linux loadable modules cannot reliably access the boot DTB physical address
directly.  Current Linux code accepts:

- `host_fdt_paddr`, or
- `host_fdt_path`, which is loaded into adapter-owned memory.

The FDT is then used to parse:

- passthrough device MMIO ranges;
- passthrough IRQ IDs;
- reserved memory regions.

Decision needed:

- Treat `host_fdt_path` as the required Linux-host mode for now;
- validate that the DTB used by AxVisor exactly matches the DTB used to boot
  the Linux host;
- validate that the injected `reserved-memory/no-map` node is visible to both
  Linux boot and AxVisor FDT parsing.

## Current Discussion Order

The fixes should be discussed in this order:

1. Define Linux `MemoryIf` address classes and mapping lifetimes.
2. Confirm guest RAM backing policy for Linux guests with passthrough DMA.
3. Decide the Linux external IRQ injection context model.
4. Decide whether the current host resource release hook is acceptable.
5. Lock down host FDT source and validation checks.

Only after those decisions should implementation continue.

## Decision Record

These items are intentionally left as discussion checkpoints.  Implementation
should not continue until the corresponding decision is accepted or revised.

### D1. Linux `MemoryIf::phys_to_virt` Contract

Proposed contract:

| HPA class | Required? | Translation rule | Lifetime |
| --- | --- | --- | --- |
| adapter-owned single frame | Yes | allocation record VA | until `dealloc_frame` |
| adapter-owned contiguous frames | Yes | allocation record VA | until `dealloc_contiguous_frames` |
| Linux guest RAM `MapIdentical` range | Yes, for Linux guest passthrough | `memremap(MEMREMAP_WB)` | at least VM lifetime |
| passthrough MMIO | Yes | `ioremap` | VM lifetime or module lifetime |
| host PLIC MMIO | Yes | `ioremap` | cached until module unload is acceptable |
| arbitrary unregistered Linux physical memory | No | return 0 / error, do not blindly `__va()` | none |

Open questions:

- Should the guest RAM `memremap` be whole-region eager mapping, chunked lazy
  mapping, or page-by-page mapping with cache records?
- Should `phys_to_virt` return 0 for unsupported HPA, or should the Rust side
  make unsupported ranges explicit with a typed error path?
- Should passthrough MMIO length come from the Rust passthrough registry rather
  than the current C-side page-size fallback?

Current implementation audit:

| HPA class | Current Linux path | Status |
| --- | --- | --- |
| adapter-owned single frame | `AXVISOR_MEM_FRAME` record inserted by `axvisor_adapter_alloc_frame`; `phys_to_virt` returns record VA. | Matches proposed contract. |
| adapter-owned contiguous frames | `AXVISOR_MEM_CONTIG` record inserted by `axvisor_adapter_alloc_contiguous_frames`; `phys_to_virt` returns record VA. | Matches proposed contract if allocation succeeds. |
| Linux guest RAM `MapIdentical` range | No explicit guest-RAM registry. Falls through to `axvisor_adapter_map_host_page()`, which uses `memremap(MEMREMAP_WB)` and caches an `AXVISOR_MEM_REMAP` record. | Functionally close, but too implicit. It may also remap arbitrary unregistered HPA. |
| passthrough MMIO | `axvisor_paddr_is_passthrough_mmio()` checks registered base HPAs, then `ioremap`s through `axvisor_adapter_ioremap_range()`. | Partly matches. C side currently assumes `PAGE_SIZE` length instead of using registered device length. |
| host PLIC MMIO | `axvisor_paddr_is_host_plic()` then `ioremap`s through `axvisor_adapter_ioremap_range()`. | Matches proposed contract. |
| arbitrary unregistered Linux physical memory | Falls through to `axvisor_adapter_map_host_page()` and attempts `memremap`. | Does not match proposed contract. This keeps a broad, Asterinas-like "try any HPA" behavior in Linux. |

Implication:

The current implementation can explain why simple guest image load and ArceOS
guest boot can work: the fallback `memremap` makes more addresses accessible
than the strict Linux contract would allow.  For a robust Linux guest contract,
the fallback should probably be narrowed to a registered guest RAM range rather
than applying to arbitrary HPA.

### D2. Linux Guest RAM Backing Policy

Proposed policy:

- Linux guest with passthrough virtio-mmio uses `MapIdentical`.
- Guest RAM GPA must equal the HPA seen by the outer QEMU device.
- The HPA range must be reserved from the Linux host at boot with
  `reserved-memory/no-map`.
- AxVisor may access the range only through the Linux mapping policy decided in
  D1.

Open questions:

- Is `MapIdentical + reserved-memory/no-map` mandatory for all Linux guests, or
  only for passthrough-DMA guests?
- Should non-passthrough Linux guest configs be allowed to use `MapAlloc`?

Current implementation audit:

| Step | Current Linux path | Status |
| --- | --- | --- |
| VM config | Linux guest config uses `memory_regions = [[0x9000_0000, 0x0400_0000, 0x7, 1]]`, where type `1` is `MapIdentical`. | Matches proposed passthrough-DMA policy. |
| Host boot reservation | `tools/run-riscv-linux-host-qemu.sh` injects `/reserved-memory/axvisor_guest_ram@90000000` with `no-map` into the host boot DTB when `AXVISOR_INJECT_RESERVED_MEMORY=1`. | Matches proposed policy if the generated boot DTB is actually used by QEMU. |
| AxVisor host FDT input | `load-axvisor.sh` passes `host_fdt_path=/root/axvisor/host-qemu-virt.dtb`. | Risk: this path must refer to the same reserved-memory-aware DTB used to boot the Linux host, not an older source DTB. |
| Reserved-memory parser | `parse_reserved_memory_regions()` adds host DTB reserved regions as `MapReserved`, but skips regions already covered by configured `memory_regions`. | For the current config, the explicit `MapIdentical` region covers the injected reserved-memory node, so no second range is added. |
| AxVM mapping | `MapIdentical` calls `map_identical_memory_region()`, which maps GPA to identical HPA and asks `MemoryIf::phys_to_virt(hpa)` for host access. | Functionally aligned, but relies on D1 fallback `memremap` because guest RAM is not explicitly registered. |

Implication:

The intended chain is coherent only if three facts are true at runtime:

1. QEMU boots Linux with the DTB containing `axvisor_guest_ram@90000000`.
2. The module receives the same DTB through `host_fdt_path`.
3. The VM config `MapIdentical` range exactly matches the reserved-memory
   range.

Current code does not appear to enforce all three as a single invariant.  If
the DTB passed to AxVisor lacks the reservation, or if the config range drifts
from the boot reservation, `phys_to_virt` can still try a broad `memremap`,
masking the configuration error until DMA or guest memory corruption appears.

### D3. Linux External IRQ Injection Model

Proposed direction:

- Do not rely on `inject_current_interrupt()` from arbitrary Linux IRQ context.
- Either inject by explicit `vm_id`, or enqueue and perform injection inside the
  vCPU thread/run-loop where current vCPU context is valid.
- PLIC completion should be coupled to guest virtual interrupt consumption, not
  merely to host claim.

Open questions:

- Which model matches the existing AxVisor core better: explicit `vm_id`
  injection, or deferred vCPU-thread injection?
- Where should the pending host IRQ be stored while waiting for the guest to
  consume it?

Current implementation audit:

| Step | Current Linux path | Status |
| --- | --- | --- |
| AxVisor IRQ API entry | `axvisor_linux_bridge::IrqIf::handle_irq()` forwards every vector to `axvisor_linux_irq_handle(vector)`. | Signature is wired. The semantic guarantee is delegated to the Linux adapter. |
| S external detection and claim | `LinuxIrqAdapter::handle_external_irq_path()` recognizes the RISC-V S external vector, claims passthrough IRQs through the host PLIC, and queues `ExternalIrqEvent`. | Functionally close to Asterinas, but uses an explicit queue instead of direct in-place iteration. |
| Core injection | `core_link::irq_vendor_bridge` eventually calls `axvisor_core::arch::riscv64::inject_current_interrupt(event.irq_id)`. | Same final core function as Asterinas. |
| vCPU context requirement | `inject_current_interrupt()` returns `false` if `try_current_vcpu_context()` fails. The vCPU loop binds current context before `vm.run_vcpu()` and calls `axvisor_api::irq::handle_irq()` on `ExternalInterrupt` exits. | Valid only when the Linux IRQ path is entered from the vCPU task's VM-exit handling path. |
| Host PLIC completion | The host PLIC is not completed immediately after claim. Guest writes to vPLIC claim/complete call `complete_passthrough_irq()`, which reaches `axvisor_linux_bridge_complete_passthrough_irq()` and then the C shim completion write. | This part matches the desired "complete after guest consumption" semantics. |
| IRQ filtering | `inject_interrupt()` drops passthrough IRQs that are not present in `cfg.pass_through_devices().irq_id`. | Correct if the host FDT parser resolved IRQ IDs correctly; silently loses interrupts if FDT/source mismatch leaves `irq_id` as zero or stale. |

Implication:

The Linux IRQ implementation is not simply "missing".  The final injection and
completion mechanisms exist.  The weak point is that the current API boundary
does not encode the required context: injection through
`inject_current_interrupt()` is only sound from the vCPU task that owns the
target VM/vCPU.  Asterinas naturally satisfies this because its task and IRQ
model is the AxVisor host model.  Linux must either keep this path strictly
inside the vCPU VM-exit handler, or switch to an explicit `vm_id` injection path
so correctness does not depend on ambient current-task state.

### D4. Linux Host Resource Release Hook

Proposed policy:

- Keep `release_host_filesystems()` as the short-term hook.
- Document that the Linux implementation releases broader passthrough host
  resources, not only filesystems.
- Later rename or split the host API if this semantic overload becomes a
  portability problem.

Open questions:

- Should serial passthrough also be part of this release list, or only
  virtio-mmio?
- Should the release hook fail hard if a requested passthrough MMIO device is
  not found or not unbound?

Current implementation audit:

| Step | Current Linux path | Status |
| --- | --- | --- |
| Asterinas host side | The Asterinas `HostIf` implementation has no `release_host_filesystems()` method in the inspected glue; it does not need to unbind Linux platform drivers. | This semantic is Linux-specific. |
| Core trigger | `vmm::init()` calls `release_host_filesystem_for_guest_passthrough()` only if some VM reports `has_host_fs_passthrough_conflict()`. | The trigger is narrower than "VM has passthrough devices"; it also requires images loaded from host filesystem. |
| Conflict predicate | `has_host_fs_passthrough_conflict()` checks `images_loaded_from_filesystem()` and non-empty passthrough devices/addresses. | Works for the current Linux-host config because `image_location = "fs"`, but not a general passthrough ownership rule. |
| Device discovery | `axvm::VM::init()` registers resolved passthrough devices through `axvisor_linux_bridge_register_passthrough_device(base_hpa, length, irq_id)`. | Good ordering for path-based devices if FDT parsing succeeded before release. |
| Release action | The C shim finds platform devices by MMIO base and calls `device_release_driver(dev)` when a driver is bound. It also uses the explicit `release_mmio_paddrs` module parameter list. | Correct Linux mechanism, but missing or stale base addresses are only logged, not treated as hard failure. |

Implication:

Linux needs a host resource release semantic that Asterinas does not need.  The
current implementation can release the virtio-mmio/serial platform drivers for
the current filesystem-backed Linux guest config, but the hook name and trigger
condition are accidental.  If a future Linux guest is loaded from memory but
still passes through MMIO devices, this hook may not run even though Linux still
owns those platform devices.

### D5. Host FDT Source

Proposed policy:

- In Linux-host mode, `host_fdt_path` is the required source for now.
- The DTB passed to AxVisor must be derived from the actual Linux boot DTB plus
  the injected guest RAM reservation.
- Startup should log enough evidence to verify that AxVisor parsed the intended
  DTB and the intended reserved RAM range.

Open questions:

- Should module load reject startup if `host_fdt_path` is missing?
- Should the adapter validate that the reserved guest RAM range exists in the
  provided host DTB before AxVisor starts?

Current implementation audit:

| Step | Current Linux path | Status |
| --- | --- | --- |
| Asterinas host side | `ArchIf::host_fdt_paddr()` returns the architecture boot FDT pointer. | AxVisor observes the real host FDT by construction. |
| Linux module input | The C shim accepts `host_fdt_path` or `host_fdt_paddr`; `host_fdt_path` is read into adapter-owned contiguous pages and exposed as `host_fdt_paddr()`. | Practical for a loadable module, but the DTB is now an external artifact that can drift from the boot DTB. |
| Host boot reservation | `tools/run-riscv-linux-host-qemu.sh` can generate a boot DTB with `reserved-memory/axvisor_guest_ram@90000000` and pass it to QEMU with `-dtb`. | Correct only if the same generated DTB is also installed at `/root/axvisor/host-qemu-virt.dtb` for module load. |
| AxVisor FDT read | `try_get_host_fdt()` calls `ArchIf::host_fdt_paddr()` and then `MemoryIf::phys_to_virt()` to parse the DTB. | Depends on D1 translation for adapter-owned contiguous memory. |
| Guest DTB construction | `handle_fdt_operations()` uses the host FDT to generate or update guest DTB, parse reserved memory, and resolve passthrough device MMIO/IRQ data. | This is the same high-level path as the working Asterinas config, but Linux lacks a hard check that the input DTB is the actual boot DTB. |

Implication:

The Linux host FDT path is currently operational but not self-validating.
Asterinas can rely on boot-time FDT provenance.  Linux cannot: the module can be
given an old or source DTB while the host was booted with a different generated
DTB.  That would leave guest RAM reservation, passthrough MMIO ranges, and IRQ
IDs internally inconsistent while still allowing early ArceOS-style smoke tests
to pass.

## Why ArceOS Can Boot While Linux Guest Still Fails

ArceOS guest success proves that the basic Linux-host embedding works:

- AxVisor core can start inside a Linux kthread.
- Basic task, wait queue, console, filesystem read, and image loading paths are
  usable.
- `MapAlloc` guest memory can be allocated and translated through adapter memory
  records.
- A simple guest can run to SBI console output and shutdown.

It does not prove the full Linux guest contract:

- Linux guest RAM uses `MapIdentical` and must be DMA-visible to the outer QEMU
  virtio-mmio device.
- Linux guest boot depends on a correct generated guest DTB, which itself depends
  on the real host DTB.
- Serial and virtio-mmio passthrough require Linux host platform drivers to be
  released before guest ownership.
- Block I/O and console interrupts require host PLIC claim, virtual PLIC
  injection, and delayed host PLIC completion to match guest behavior.
- IRQ injection depends on either correct current vCPU context or explicit VM
  targeting.

So the current situation is: the Linux glue is wired far enough to boot a simple
guest, but it is not yet proven semantically equivalent to the Asterinas host
for the Linux guest path.  The highest-risk remaining gaps are D1, D3, D4, and
D5; D2 is conceptually correct but lacks runtime invariant checks.
