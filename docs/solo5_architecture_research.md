# Solo5 Architecture Research Report

This document provides a thorough technical analysis of Solo5's architecture, interfaces, and
internals, structured to enable direct comparison with KVM's Linux interface.

All source references are from the Solo5 GitHub repository (github.com/Solo5/solo5), current
as of the latest master branch.

---

## 1. What Solo5 Is and What Problem It Solves

Solo5 is a **sandboxed execution environment** for unikernels (library operating systems such as
MirageOS, IncludeOS, and HaLVM). It redefines the interface between a unikernel and its host
OS/hypervisor to be:

- **Legacy-free**: No emulated hardware (no PCI, no PIC, no PIT, no legacy BIOS interfaces).
  Compare with KVM/QEMU which must emulate x86 hardware (i8254 PIT, i8259 PIC, PCI bus, VGA, etc.)
- **Thin**: A minimal interface surface with ~15 operations total, vs. the hundreds of ioctls,
  msr writes, and port I/O operations in KVM.
- **Secure by construction**: The small interface makes it easy to reason about isolation. The
  spt (seccomp) target whitelists only 7 Linux syscalls.

Solo5's key design decisions:
- **No interrupts**: All I/O is polling-based, which makes execution deterministic and enables
  efficient record/replay and debugging.
- **No SMP**: Single vCPU only. Scaling is achieved by running multiple instances.
- **No scheduling**: Cooperative scheduling only. The unikernel explicitly yields via
  `solo5_yield()`.
- **Fast boot**: Comparable to loading a regular user process, suitable for "function as a service"
  use cases.

---

## 2. The Interface Between Unikernel and Host

Solo5 defines a **layered interface** with three levels:

### Level 1: Public API (include/solo5.h)

The unikernel programs against a single C header: `include/solo5.h`. This defines the complete
interface between the unikernel application and Solo5. Key elements:

**Entry point:**
```c
struct solo5_start_info {
    const char *cmdline;
    uintptr_t heap_start;
    size_t heap_size;
};
int solo5_app_main(const struct solo5_start_info *info);
```

**Lifecycle:**
```c
void solo5_exit(int status);    // __attribute__((noreturn))
void solo5_abort(void);         // returns SOLO5_EXIT_ABORT (255)
```

**Time:**
```c
typedef uint64_t solo5_time_t;  // nanoseconds
solo5_time_t solo5_clock_monotonic(void);  // TSC-based, fast but may drift
solo5_time_t solo5_clock_wall(void);       // host wall clock, hypercall
```

**I/O handles:**
```c
typedef uint64_t solo5_handle_t;
typedef uint64_t solo5_handle_set_t;  // bitmask of up to 64 handles
void solo5_yield(solo5_time_t deadline, solo5_handle_set_t *ready_set);
```

**Console:**
```c
void solo5_console_write(const char *buf, size_t size);  // best-effort
```

**Network:**
```c
solo5_result_t solo5_net_acquire(const char *name, solo5_handle_t *handle,
                                 struct solo5_net_info *info);
solo5_result_t solo5_net_write(solo5_handle_t handle, const uint8_t *buf, size_t size);
solo5_result_t solo5_net_read(solo5_handle_t handle, uint8_t *buf, size_t size,
                              size_t *read_size);
```

**Block:**
```c
solo5_result_t solo5_block_acquire(const char *name, solo5_handle_t *handle,
                                   struct solo5_block_info *info);
solo5_result_t solo5_block_write(solo5_handle_t handle, solo5_off_t offset,
                                 const uint8_t *buf, size_t size);
solo5_result_t solo5_block_read(solo5_handle_t handle, solo5_off_t offset,
                                uint8_t *buf, size_t size);
```

**TLS:**
```c
size_t solo5_tls_size(void);
uintptr_t solo5_tls_tp_offset(uintptr_t tls);
solo5_result_t solo5_tls_init(uintptr_t tls);
solo5_result_t solo5_set_tls_base(uintptr_t base);
```

### Level 2: Internal ABI (target-specific)

Each target has its own internal ABI between the guest (unikernel binding) and the host (tender):

- **hvt**: Hypercall ABI via PIO (x86) or MMIO (aarch64) traps, defined in `include/hvt_abi.h`
- **spt**: Direct Linux system calls (whitelisted by seccomp), defined in `include/spt_abi.h`
- **virtio**: VirtIO paravirtualized device protocol
- **muen**: Muen separation kernel channels
- **xen**: Xen hypercall interface

### Level 3: Target Backend

The actual host-side mechanism:
- **hvt on Linux**: Uses KVM ioctls to create a VM, set up memory, and run a vCPU. Hypercalls
  are PIO/MMIO exits dispatched to module handlers.
- **hvt on FreeBSD**: Uses vmm(4) ioctls similarly.
- **spt**: Loads the unikernel ELF into host memory, installs seccomp filter, and jumps to entry.
  The unikernel makes direct Linux syscalls.

---

## 3. The "Tender" Concept

A **tender** is the host-side process responsible for loading, configuring, and managing the
unikernel. It is analogous to QEMU in a KVM setup, but orders of magnitude simpler.

### hvt (Hardware Virtualized Tender)

Location: `tenders/hvt/`

- Creates a KVM (or vmm) VM with a single vCPU
- Loads the unikernel ELF into guest memory starting at 0x100000
- Sets up `struct hvt_boot_info` in guest low memory
- Enters the vCPU run loop
- On VM exit (PIO/MMIO trap), dispatches to registered hypercall handlers
- Modular: functionality is added via "modules" (block, net, time, etc.)
- Applies seccomp filter to the tender itself before entering the vCPU loop

Key tender data structures:
```c
struct hvt {
    uint8_t *mem;              // Host-side pointer to guest memory
    size_t guest_mem_size;
    size_t mem_alloc_size;
    uint64_t cpu_cycle_freq;
    hvt_gpa_t cpu_boot_info_base;
    struct hvt_b *b;           // Backend-specific data
};
```

Module registration:
```c
struct hvt_module_ops {
    int (*setup)(struct hvt *hvt, struct mft *mft);
    int (*handle_cmdarg)(char *cmdarg, struct mft *mft);
    const char *(*usage)(void);
    void (*install_seccomp_rules)(void *ctx);  // Linux only
};
```

### spt (Sandboxed Process Tender)

Location: `tenders/spt/`

- Loads the unikernel ELF into host memory (mmap'd)
- Installs a strict seccomp whitelist allowing only 7 syscalls:
  `read`, `write`, `pread64`, `pwrite64`, `clock_gettime`, `exit_group`, `epoll_pwait`,
  `timerfd_settime` (and `arch_prctl` on x86_64)
- Sets up `struct spt_boot_info` in guest memory
- Jumps to the unikernel entry point (the unikernel runs as a regular userspace function call)
- The unikernel makes raw syscalls via inline assembly (no libc)

Key tender data structures:
```c
struct spt {
    uint8_t *mem;
    size_t mem_size;
    struct spt_boot_info *bi;
    int epollfd;     // for yield() implementation
    int timerfd;     // for yield() deadlines
    void *sc_ctx;    // seccomp context
};
```

### Other Targets (no separate tender process)

- **virtio**: Unikernel runs as a QEMU/KVM VM using standard VirtIO devices. Loaded by QEMU.
- **genode**: Runs on the Genode OS framework as a component.
- **muen**: Runs on the Muen separation kernel.
- **xen**: Runs as a Xen PV guest (domU).

---

## 4. Solo5's Hypercall/Syscall Interface

### hvt Hypercall ABI (include/hvt_abi.h)

**ABI Version**: 2

**Guest minimum load address**: 0x100000 (1MB)

**Hypercall mechanism**:
- **x86_64**: PIO port I/O to `0x500 + n` (where n is hypercall number). Uses `outl` instruction.
- **aarch64**: MMIO store to `0x100000000 + (n << 3)`. Uses `str` instruction.

**Ring I/O kick mechanism** (for ioeventfd):
- **x86_64**: PIO write to port 0x600. Does NOT cause a VM exit when KVM_IOEVENTFD is registered.
- **aarch64**: MMIO write to `0x100000100`.

**Canonical hypercalls** (enum hvt_hypercall):

| # | Name | Purpose | Structure |
|---|------|---------|-----------|
| 1 | HVT_HYPERCALL_WALLTIME | Get host wall clock time | `hvt_hc_walltime` (out: nsecs) |
| 2 | HVT_HYPERCALL_PUTS | Write to console | `hvt_hc_puts` (in: data ptr, len) |
| 3 | HVT_HYPERCALL_POLL | Wait until deadline or I/O ready | `hvt_hc_poll` (in: timeout_nsecs, out: ready_set) |
| 4 | HVT_HYPERCALL_BLOCK_WRITE | Write block device sector | `hvt_hc_block_write` (in: handle, offset, data, len; out: ret) |
| 5 | HVT_HYPERCALL_BLOCK_READ | Read block device sector | `hvt_hc_block_read` (in: handle, offset, data; in/out: len; out: ret) |
| 6 | HVT_HYPERCALL_NET_WRITE | Send network packet | `hvt_hc_net_write` (in: handle, data, len; out: ret) |
| 7 | HVT_HYPERCALL_NET_READ | Receive network packet | `hvt_hc_net_read` (in: handle, data; in/out: len; out: ret) |
| 8 | HVT_HYPERCALL_HALT | Terminate guest | `hvt_hc_halt` (in: cookie, exit_status) |

**Feature negotiation** (in hvt_boot_info):
- `HVT_FEATURE_RING_IO (1 << 0)`: Shared ring buffer for network I/O (avoids VM exits).

**Boot information** passed to guest entry point:
```c
struct hvt_boot_info {
    uint64_t mem_size;            // Total guest memory in bytes
    uint64_t kernel_end;          // Address of end of kernel image
    uint64_t cpu_cycle_freq;      // TSC frequency in Hz
    const char *cmdline;          // Command line string (guest pointer)
    const void *mft;              // Application manifest (guest pointer)
    uint32_t host_features;       // Feature flags from tender
    uint32_t guest_features;      // Feature flags accepted by guest
    void *net_ring;               // GPA of network ring buffer (0 if absent)
};
```

### spt Syscall Interface (include/spt_abi.h + bindings/spt/sys_linux_x86_64.c)

The spt target uses **direct Linux syscalls** (inline assembly, no libc). The seccomp filter
whitelists exactly these syscalls on x86_64:

| Syscall # | Name | Purpose |
|-----------|------|---------|
| 0 | read | Block/network read |
| 1 | write | Console/block/network write |
| 17 | pread64 | Block read at offset |
| 18 | pwrite64 | Block write at offset |
| 158 | arch_prctl | TLS setup (x86_64 only) |
| 228 | clock_gettime | Monotonic and wall clocks |
| 231 | exit_group | Exit |
| 281 | epoll_pwait | Yield/wait for I/O |
| 286 | timerfd_settime | Deadline timers for yield |

**Boot information**:
```c
struct spt_boot_info {
    uint64_t mem_size;
    uint64_t kernel_end;
    const char *cmdline;
    const void *mft;
    int epollfd;     // pre-configured epoll set for yield()
    int timerfd;     // pre-configured timerfd for deadlines
};
```

### Ring I/O Optimization (include/hvt_ring.h)

For the hvt target, an optional shared-memory ring buffer can be used for network I/O to avoid
VM exits. This uses KVM ioeventfd for kick notification without VM exits.

```c
struct hvt_ring {
    // Cache line 0: written ONLY by the guest
    volatile uint32_t ent_tail;   // guest produces entries
    volatile uint32_t com_head;   // guest consumes completions
    uint8_t _pad0[56];

    // Cache line 1: written ONLY by the host
    volatile uint32_t ent_head;   // host consumes entries
    volatile uint32_t com_tail;   // host produces completions
    volatile uint32_t needs_kick; // host sets before sleeping
    uint8_t _pad1[52];

    struct hvt_ring_entry entries[1024];
    struct hvt_ring_commit commits[1024];
};
```

The ring uses an SPSC (single-producer, single-consumer) design with proper memory barriers:
- x86_64: compiler barriers for wmb/rmb (TSO provides ordering), `mfence` for full barrier
- aarch64: `dmb ishst` for wmb, `dmb ishld` for rmb, `dmb ish` for full barrier

---

## 5. How Solo5 Handles Key Resources

### 5.1 Memory Management

**Memory layout** (from linker script `bindings/solo5_hvt.lds`):

```
0x000000 - 0x0FFFFF: Reserved (below TEXT_START)
0x100000:            Text segment (executable, read-only)
                     Includes: .interp, .text, .text.*
                     PT_LOAD, FLAGS=1 (execute only)

_page aligned_
                     Read-only data segment
                     Includes: .note.solo5.manifest, .note.solo5.abi,
                               .note.solo5.not_openbsd, .rodata, .eh_frame
                     PT_LOAD, FLAGS=4 (read only)

_page aligned_
                     Data segment (read-write)
                     Includes: .got, .data, .tdata
                     PT_LOAD (read-write)

_page aligned_
                     BSS segment (zero-initialized)
                     Includes: .tbss, .bss
                     PT_LOAD

_end:                Heap starts here (page-aligned)
                     ...
                     Heap grows upward
                     ...
                     Stack grows downward from (mem_size)
```

The unikernel receives `heap_start` (at `_end`, page-aligned) and `heap_size` (mem_size - heap_start).
The initial stack is placed at `heap_start + heap_size` and grows downward.

**Memory initialization** (bindings/mem.c):
```c
void mem_init(void) {
    extern char _stext[], _etext[], _erodata[], _end[];
    heap_start = ((uint64_t)&_end + PAGE_SIZE - 1) & PAGE_MASK;
    // Minimum 512KB free memory required
}

void mem_lock_heap(uintptr_t *start, size_t *size) {
    *start = heap_start;
    *size = platform_mem_size() - heap_start;
}
```

Before `solo5_app_main()` is called, internal subsystems can allocate pages from the heap via
`mem_ialloc_pages()`. After `mem_lock_heap()`, all remaining memory is given to the application.

### 5.2 I/O (General Model)

Solo5 uses a **synchronous, blocking I/O model**:
- All I/O operations are synchronous function calls
- No async I/O, no DMA (from the unikernel perspective), no interrupt-driven I/O
- Network reads are non-blocking (returns SOLO5_R_AGAIN if no packet)
- Network writes are fire-and-forget (packet may be silently dropped)
- Block reads/writes are exactly one block at a time (currently)
- The unikernel suspends via `solo5_yield()` to wait for I/O readiness or a timeout

### 5.3 Networking

**Device model**: Raw Ethernet frame interface. No TCP/IP offload, no checksum offload, no
interrupt-driven RX.

**Acquire**: `solo5_net_acquire()` looks up the device by name in the manifest, returns a handle
(an index into the manifest entry array) and device info (MAC address, MTU).

**Write** (hvt binding, with ring optimization):
1. If ring I/O is available (negotiated via HVT_FEATURE_RING_IO):
   - Copy packet into a per-slot buffer in BSS
   - Fill ring entry with operation, handle, data pointer, length
   - Submit via ring (increment ent_tail)
   - Kick via ioeventfd (only if host needs_kick)
   - Fire-and-forget: no completion wait
2. Otherwise: HVT_HYPERCALL_NET_WRITE hypercall (synchronous)

**Read** (hvt binding, with ring optimization):
1. If ring I/O is available:
   - Fill ring entry with NET_READ operation
   - Submit and wait for host completion (spin on com_head)
2. Otherwise: HVT_HYPERCALL_NET_READ hypercall

**Write** (spt binding): Uses `sys_write()` or `sys_pwrite64()` syscall on the host fd.
**Read** (spt binding): Uses `sys_read()` syscall on the host fd.

### 5.4 Block Devices

**Device model**: Simple read/write at byte offset. Currently limited to single-block operations.

**Acquire**: `solo5_block_acquire()` looks up device by name in manifest, returns handle and
info (capacity, block_size).

**Write** (hvt): HVT_HYPERCALL_BLOCK_WRITE hypercall with (handle, offset, data, len).
The binding validates offset alignment and enforces single-block size.
**Read** (hvt): HVT_HYPERCALL_BLOCK_READ hypercall.

**Write** (spt): `sys_pwrite64()` syscall on the host file descriptor.
**Read** (spt): `sys_pread64()` syscall on the host file descriptor.

### 5.5 Time/Clocks

**Monotonic clock**: TSC-based. Initialized from `hvt_boot_info.cpu_cycle_freq`.
Read via `rdtsc`/`rdtscp` on x86, CNTVCT on aarch64. Fast (no hypercall), but may drift if
the VM is suspended.

**Wall clock**: Requires a hypercall (`HVT_HYPERCALL_WALLTIME` on hvt, `clock_gettime(CLOCK_REALTIME)`
on spt). More accurate but slower.

**Yield/Wait**: `solo5_yield(deadline, &ready_set)`:
- On hvt: HVT_HYPERCALL_POLL with relative timeout
- On spt: Uses `timerfd_settime()` + `epoll_pwait()` to sleep until deadline or I/O

### 5.6 Console Output

`solo5_console_write(buf, size)` is a **best-effort** write:
- On hvt: HVT_HYPERCALL_PUTS hypercall
- On spt: `sys_write(1, buf, size)` (stdout)
- Data may be lost under resource pressure

---

## 6. The Solo5 Manifest and Memory Layout Mechanism

### Application Manifest

The manifest declares the unikernel's resource requirements at build time.

**Build process**:
1. Developer writes `manifest.json`:
   ```json
   {
     "type": "solo5.manifest",
     "version": 1,
     "devices": [
       { "name": "frontend", "type": "NET_BASIC" },
       { "name": "storage", "type": "BLOCK_BASIC" }
     ]
   }
   ```

2. `solo5-elftool` processes this into a C source file containing the binary manifest
3. The C source is compiled and linked into the unikernel as an ELF NOTE (type "MFT1")
4. At runtime, the tender extracts and validates the manifest from the ELF binary

**Manifest binary format** (from include/mft_abi.h):
```c
struct mft {
    uint32_t version;      // MFT_VERSION = 1
    uint32_t entries;      // Number of device entries
    struct mft_entry e[];  // Variable-length array (up to 64 entries)
};

struct mft_entry {
    char name[68];         // Device name (1-67 chars + null)
    mft_type_t type;       // MFT_DEV_BLOCK_BASIC or MFT_DEV_NET_BASIC
    union {
        struct mft_block_basic block_basic;  // capacity, block_size
        struct mft_net_basic net_basic;       // mac[6], mtu
    } u;
    union {
        int hostfd;        // Host file descriptor (tender-side)
        void *data;        // Backing object (tender-side)
    } b;
    bool attached;         // Whether device is attached at runtime
};
```

Maximum: 64 entries (MFT_MAX_ENTRIES), constrained to fit in a solo5_handle_set_t (uint64_t bitmask).

### ELF Notes

The unikernel binary contains two Solo5-specific ELF NOTEs:

1. **ABI1** (`.note.solo5.abi`): Declares the target ABI and version
   ```c
   struct abi1_info {
       uint32_t abi_target;   // HVT_ABI_TARGET, SPT_ABI_TARGET, etc.
       uint32_t abi_version;  // Target-specific version
       uint32_t reserved0;
       uint32_t reserved1;
   };
   ```

2. **MFT1** (`.note.solo5.manifest`): Contains the binary manifest

3. **PT_INTERP** (`.interp`): Set to "/nonexistent/solo5/" to prevent the host kernel from
   loading the binary as a regular ELF executable.

### Boot Sequence (hvt target)

1. **Tender** (solo5-hvt) parses command-line arguments
2. Loads the unikernel ELF into guest memory
3. Validates the ABI1 and MFT1 notes
4. Sets up host resources (tap device, block file) matching manifest entries
5. Calls `hvt_boot_info_init()` to write `struct hvt_boot_info` into guest memory
6. Optionally sets up ring buffer for network I/O
7. Drops privileges (seccomp on the tender)
8. Enters vCPU run loop (`hvt_vcpu_loop()`)

### Guest Entry Point

1. Guest `_start(arg)` is called with a pointer to `hvt_boot_info` (or `spt_boot_info`)
2. CRT initialization: stack canary, TLS
3. Console init, CPU init
4. `platform_init(arg)`: extracts cmdline and mem_size from boot info
5. `mem_init()`: computes heap_start from `_end` symbol
6. `time_init()`: initializes TSC clock from `cpu_cycle_freq`
7. `block_init()` / `net_init()`: stores manifest pointer, optionally sets up ring
8. `mem_lock_heap()`: computes final heap_start and heap_size
9. `solo5_app_main(&si)` is called with the start info
10. Return value is passed to `solo5_exit()` -> `HVT_HYPERCALL_HALT`

---

## 7. Comparison Summary: Solo5 vs KVM/Linux

| Aspect | Solo5 (hvt) | KVM/Linux |
|--------|-------------|-----------|
| **Interface size** | ~8 hypercalls | ~200+ ioctls, msrs, CPUID leaves |
| **Device model** | Abstract (BLOCK_BASIC, NET_BASIC) | Full hardware emulation (PCI, virtio) |
| **Interrupts** | None (polling only) | Full interrupt controller (APIC, IOAPIC) |
| **SMP** | No | Yes (up to many vCPUs) |
| **Memory** | Flat, contiguous, single region | Complex (EPT, SPT, balloon, NUMA) |
| **Boot** | Direct ELF load, ~15 C functions | BIOS/UEFI firmware, bootloader chain |
| **Console** | Single hypercall (puts) | VGA, serial (16550), virtio-serial |
| **Network** | Raw frame read/write | virtio-net, e1000, with offloads |
| **Block** | Byte-offset read/write | virtio-blk, IDE, SCSI |
| **Time** | TSC + wall clock hypercall | TSC, HPET, PIT, RTC, kvmclock |
| **Host interface** | PIO/MMIO trap -> dispatch | KVM_GET_REGS, KVM_SET_REGS, KVM_RUN, etc. |
| **Security** | Tender drops privs + seccomp | QEMU has large attack surface |
| **Code size** | ~10K LOC tender | QEMU: millions of LOC |
