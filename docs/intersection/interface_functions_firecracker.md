# Firecracker 侧 36 个 Hypervisor↔OS 接口的真实函数/源码映射

> 从本仓库参考源码树 `code/firecracker-reference/`（Firecracker，Rust 用户态 VMM）逐个抽取。
> Firecracker 是用户态 VMM：内核级能力（EPT 翻译、页面锁定、LAPIC/IOAPIC 模拟、中断注入等）
> 通过 `/dev/kvm` 的 KVM ioctl 代理，底层由 KVM 内核实现；virtio 设备、事件循环、seccomp、jailer 由 Firecracker 自实现。
>
> 标注约定：
> - `[KVM 代理]` — Firecracker 发 ioctl，内核实现
> - `[FC 自实现]` — Firecracker 自己的 Rust 代码实现
> - `[libc/syscall]` — 直接 Linux 系统调用
> - `[未找到]` — 参考树中未找到

---

## 维度 1：内存管理

### 1) Guest 内存分配与映射 — `mmap` + `KVM_SET_USER_MEMORY_REGION` [libc/syscall + KVM 代理]

Firecracker 用 `mmap` 匿名分配宿主内存，再通过 `set_user_memory_region` ioctl 注册为 guest 物理地址空间。

分配（`src/vmm/src/vstate/memory.rs:160-192`，`GuestMemoryExtension::from_raw_regions`）：

```rust
fn from_raw_regions(regions, track_dirty_pages, huge_pages) -> Result<Self, MemoryError> {
    let prot = libc::PROT_READ | libc::PROT_WRITE;
    let flags =
        libc::MAP_NORESERVE | libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | huge_pages.mmap_flags();
    ...
    let region = MmapRegionBuilder::new_with_bitmap(*region_size, bitmap)
        .with_mmap_prot(prot)
        .with_mmap_flags(flags)
        .build()?;
    GuestRegionMmap::new(region, *guest_address)
    ...
}
```

注册进 KVM（`src/vmm/src/vstate/vm.rs:227-254`，`set_kvm_memory_regions`）：

```rust
let memory_region = kvm_userspace_memory_region {
    slot,
    guest_phys_addr: region.start_addr().raw_value(),
    memory_size: region.len(),
    userspace_addr: guest_mem.get_host_address(region.start_addr()).unwrap() as u64,
    flags,
};
// SAFETY: Safe because the fd is a valid KVM file descriptor.
unsafe { self.fd.set_user_memory_region(memory_region) }   // ioctl KVM_SET_USER_MEMORY_REGION
```

语义：静态分配一整块 guest RAM（启动后不可变），建立 HVA→GPA slot 映射；实际页表/EPT 由 KVM 内核建立。

### 2) 页面锁定 / 防换出 — 无 `mlock`，仅 `MAP_NORESERVE`（+ 可选 hugetlb）[FC 自实现/依赖内核缺页]

参考树中未见 `mlock`/`mlockall`。Firecracker 显式使用 `MAP_NORESERVE`（见上 `memory.rs:171-172`），即**不预留 swap、按需缺页**，与"锁定防换出"相反。锁定语义交由部署侧（cgroup/hugetlb）而非 VMM 自身。huge page 通过 `huge_pages.mmap_flags()`（`MAP_HUGETLB`）实现，`src/vmm/src/vstate/memory.rs:172`。结论：**Firecracker 侧无页面锁定接口**（防换出不由 VMM 主动做）。

### 3) GPA→HPA 翻译 — KVM 内核实现；Firecracker 侧只有 HVA 计算 [KVM 代理]

真正的 GPA→HPA 由 KVM 建立 EPT/NPT 页表，Firecracker 用户态无此能力。Firecracker 侧只做 **GPA→HVA**（宿主虚拟地址）计算，供上面 `userspace_addr` 使用：

- `guest_mem.get_host_address(...)`（`vm-memory` crate 的 `GuestMemory` trait），调用点 `src/vmm/src/vstate/vm.rs:245`。

翻译到物理页帧、缺页填充均在 `KVM_RUN` 内核态完成。

### 4) 脏页追踪 — `KVM_MEM_LOG_DIRTY_PAGES` + 用户态 bitmap [KVM 代理 + FC 自实现]

创建 memslot 时置标志启用内核脏页日志（`src/vmm/src/vstate/vm.rs:232-235`）：

```rust
let mut flags = 0u32;
if track_dirty_pages {
    flags |= KVM_MEM_LOG_DIRTY_PAGES;
}
```

用户态另有 `AtomicBitmap` 记录写脏（`from_raw_regions` 里 `MmapRegionBuilder::new_with_bitmap`，`memory.rs:177-181`），`mark_dirty`（`memory.rs:283-290`）在 dump 时用于 diff snapshot / 增量迁移。

### 5) MMU 反向通知 [分歧] — 无 mmu_notifier；balloon 用 `madvise(MADV_DONTNEED)` [FC 自实现/libc]

内核 `mmu_notifier` 属 KVM 内核机制，Firecracker 无对应用户态接口。与内存回收最接近的是 balloon 设备主动 `madvise` 释放物理页（`src/vmm/src/devices/virtio/balloon/util.rs:105-108`）：

```rust
let ret = unsafe {
    libc::madvise(phys_address.cast(), range_len, libc::MADV_DONTNEED)
};
```

语义：guest 气球膨胀 → host 用 `MADV_DONTNEED` 归还页帧。这是 VMM→内核方向的提示，非内核→VMM 的反向通知。**MMU 反向通知在 Firecracker 侧未实现。**


## 维度 2：vCPU 管理

### 6) 硬件虚拟化启用 — `Kvm::new()` (`open /dev/kvm`) + `KVM_CREATE_VM` + 能力探测 [KVM 代理]

Firecracker 不直接操作 VMX/SVM，硬件虚拟化由 KVM 打开。入口 `Vm::new`（`src/vmm/src/vstate/vm.rs:135-151`）：

```rust
pub fn new(kvm_cap_modifiers: Vec<KvmCapability>) -> Result<Self, VmError> {
    let kvm = Kvm::new().map_err(VmError::Kvm)?;   // open("/dev/kvm") + KVM_GET_API_VERSION
    if kvm.get_api_version() != KVM_API_VERSION as i32 { ... }
    let total_caps = Self::combine_capabilities(&kvm_cap_modifiers);
    Self::check_capabilities(&kvm, &total_caps)?;   // 逐个 KVM_CHECK_EXTENSION
    let max_memslots = kvm.get_nr_memslots();
    let vm_fd = kvm.create_vm().map_err(VmError::VmFd)?;   // ioctl KVM_CREATE_VM
    ...
}
```

x86_64 默认探测的能力集（`vm.rs:328-343`，14 个）：`KVM_CAP_IRQCHIP / IOEVENTFD / IRQFD / USER_MEMORY / SET_TSS_ADDR / PIT2 / PIT_STATE2 / ADJUST_CLOCK / DEBUGREGS / MP_STATE / VCPU_EVENTS / XCRS / XSAVE / EXT_CPUID`。`check_capabilities` 用 `kvm.check_extension_raw`（`vm.rs:199-207`），即 ioctl `KVM_CHECK_EXTENSION`。VMX/SVM 使能、EPT 全部在内核 `KVM_CREATE_VM` 内完成。

### 7) vCPU 创建 / 销毁 — `KVM_CREATE_VCPU` [KVM 代理]

`KvmVcpu::new`（`src/vmm/src/vstate/vcpu/x86_64.rs:167-179`）：

```rust
pub fn new(index: u8, vm: &Vm) -> Result<Self, KvmVcpuError> {
    let kvm_vcpu = vm.fd().create_vcpu(index.into())   // ioctl KVM_CREATE_VCPU
        .map_err(KvmVcpuError::VcpuFd)?;
    Ok(KvmVcpu { index, fd: kvm_vcpu, peripherals: Default::default(),
                 msrs_to_save: vm.msrs_to_save().as_slice().to_vec() })
}
```

销毁：无显式 ioctl，vCPU `fd` 随 `VcpuFd` Drop 时 `close(2)`。snapshot 恢复路径也用 `create_vcpu_from_rawfd`（`vcpu/mod.rs:252`）。

### 8) vCPU 执行 — `KVM_RUN` [KVM 代理]

热路径核心。`Vcpu::run_emulation`（`src/vmm/src/vstate/vcpu/mod.rs:493-518`）：

```rust
pub fn run_emulation(&mut self) -> Result<VcpuEmulation, VcpuError> {
    if self.kvm_vcpu.fd.get_kvm_run().immediate_exit == 1u8 { ... }
    match self.kvm_vcpu.fd.run() {                 // ioctl KVM_RUN
        Err(ref err) if err.errno() == libc::EINTR => {
            self.kvm_vcpu.fd.set_kvm_immediate_exit(0);
            Ok(VcpuEmulation::Interrupted)         // 被信号 kick 中断
        }
        emulation_result => handle_kvm_exit(&mut self.kvm_vcpu.peripherals, emulation_result),
    }
}
```

`kvm_run` 结构由 `KVM_GET_VCPU_MMAP_SIZE` + mmap 得到（kvm-ioctls 内部）；`EINTR` 表示被 kick 信号打断（对应维度 6 唤醒）。

### 9) 寄存器读写 — `KVM_{GET,SET}_REGS` / `KVM_{GET,SET}_SREGS` [KVM 代理]

保存路径 `KvmVcpu::save_state`（`vcpu/x86_64.rs:496-497`）：

```rust
let regs = self.fd.get_regs().map_err(KvmVcpuError::VcpuGetRegs)?;   // KVM_GET_REGS
let sregs = self.fd.get_sregs().map_err(KvmVcpuError::VcpuGetSregs)?; // KVM_GET_SREGS
```

恢复路径 `restore_state`（`vcpu/x86_64.rs:598-601`）：`self.fd.set_regs(&state.regs)` / `set_sregs(&state.sregs)`（ioctl `KVM_SET_REGS` / `KVM_SET_SREGS`）。用于设置初始 RIP/RSP/RFLAGS 和 snapshot。

### 10) CPUID 过滤 — `KVM_GET_SUPPORTED_CPUID` + `normalize` + `KVM_SET_CPUID2` [KVM 代理 + FC 自实现过滤]

宿主能力探测（`vm.rs:165-166`）：`kvm.get_supported_cpuid(KVM_MAX_CPUID_ENTRIES)`（ioctl `KVM_GET_SUPPORTED_CPUID`）。
Firecracker 在用户态做过滤/规整后再下发（`vcpu/x86_64.rs:195-213`）：

```rust
let mut cpuid = vcpu_config.cpu_config.cpuid.clone();
cpuid.normalize(self.index, vcpu_config.vcpu_count, ...)?;   // FC 自实现的 CPUID 规整
let kvm_cpuid = kvm_bindings::CpuId::try_from(cpuid)?;
self.fd.set_cpuid2(&kvm_cpuid)                                // ioctl KVM_SET_CPUID2
    .map_err(KvmVcpuConfigureError::SetCpuid)?;
```

`normalize` 及 CPU template 逻辑（拓扑、feature 屏蔽）是 Firecracker 自实现，最终仍经 KVM ioctl 生效。

### 11) MSR 模拟 — `KVM_{GET,SET}_MSRS` + `KVM_GET_MSR_INDEX_LIST` [KVM 代理]

批量写 boot MSR（`arch/x86_64/msr.rs:437-439`，`set_msrs`）：

```rust
pub fn set_msrs(vcpu: &VcpuFd, msr_entries: &[kvm_msr_entry]) -> Result<(), MsrError> {
    let msrs = Msrs::from_entries(msr_entries)?;
    vcpu.set_msrs(&msrs)   // ioctl KVM_SET_MSRS
    ...
}
```

读取（`vcpu/x86_64.rs:457-470`，`get_msrs` → `get_msr_chunks` → `self.fd.get_msrs`，ioctl `KVM_GET_MSRS`）。可 dump 的 MSR 索引由 `get_msrs_to_dump` / `get_msrs_to_save`（`arch/x86_64/msr.rs:267,388`）经 ioctl `KVM_GET_MSR_INDEX_LIST` 得到。MSR 真正读写语义在内核；Firecracker 只选择索引与数值。

### 12) VM exit 分发 [分歧] — 用户态 `handle_kvm_exit` match [FC 自实现]

KVM 返回后的分发在 Firecracker 用户态完成（`src/vmm/src/vstate/vcpu/mod.rs:522-608`）：

```rust
fn handle_kvm_exit(peripherals: &mut Peripherals,
                   emulation_result: Result<VcpuExit, errno::Error>) -> Result<VcpuEmulation, VcpuError> {
    match emulation_result {
        Ok(run) => match run {
            VcpuExit::MmioRead(addr, data)  => { peripherals.bus.read(addr, data); ... }
            VcpuExit::MmioWrite(addr, data) => { peripherals.bus.write(addr, data); ... }
            VcpuExit::Hlt      => Ok(VcpuEmulation::Stopped),
            VcpuExit::Shutdown => Ok(VcpuEmulation::Stopped),
            VcpuExit::FailEntry(...)     => { ... }
            VcpuExit::InternalError      => { ... }
            VcpuExit::SystemEvent(...)   => { ... }
        },
        ...
    }
}
```

分歧点：exit 原因由内核在 `KVM_RUN` 决定并写 `kvm_run.exit_reason`，但**MMIO/HLT/shutdown 的语义处理由 Firecracker 用户态实现**（MMIO 直接派发到 `peripherals.bus`），这与内核态设备模拟的 hypervisor 不同。


## 维度 3：I/O 模型

### 13) PIO/MMIO 拦截 — `KVM_EXIT_MMIO` → 用户态 `Bus` 派发 [KVM 代理触发 + FC 自实现处理]

拦截由内核在 `KVM_RUN` 触发（`kvm_run.exit_reason = KVM_EXIT_MMIO`），派发到 Firecracker 自实现的地址总线。exit 处理见 `vcpu/mod.rs:528-542`（`peripherals.bus.read/write`）。总线本体 `src/vmm/src/devices/bus.rs:169-198`：

```rust
pub fn read(&mut self, offset: u64, data: &mut [u8]) {
    if let Some((base, dev)) = self.first_before(offset) {
        let offset = offset - base;
        dev.lock().read(base, offset, data);   // 命中区间的设备
    }
}
pub fn write(&mut self, offset: u64, data: &[u8]) {
    if let Some((base, dev)) = self.first_before(offset) { ... dev.lock().write(base, offset, data); }
}
```

Firecracker 只用 virtio-mmio，几乎不用 PIO（`KVM_EXIT_IO` 极少）。真正拦截（EPT/VMCS）在内核，语义处理在用户态。

### 14) I/O 事件通知 eventfd — `KVM_IOEVENTFD` + `eventfd(2)` [KVM 代理 + libc]

virtio 通知快路径：把 guest 写 NOTIFY 寄存器的动作直接映射为 eventfd 触发，避免 VM exit。注册在 `device_manager/mmio.rs:197-202`：

```rust
for (i, queue_evt) in locked_device.queue_events().iter().enumerate() {
    let io_addr = IoEventAddress::Mmio(
        device_info.addr + u64::from(crate::devices::virtio::NOTIFY_REG_OFFSET),
    );
    vm.register_ioevent(queue_evt, &io_addr, u32::try_from(i).unwrap())   // ioctl KVM_IOEVENTFD
        .map_err(MmioError::RegisterIoEvent)?;
}
```

底层 eventfd 由 `vmm-sys-util::eventfd::EventFd::new(EFD_NONBLOCK)` 创建（`syscall(SYS_eventfd2)`），vmm crate 广泛使用于 kick / 通知。

### 15) virtio 设备 — Firecracker 自实现 virtio-mmio 传输层 [FC 自实现]

virtio 传输、队列、协议全部为 Firecracker 自实现，不依赖内核。传输层 `MmioTransport`（`src/vmm/src/devices/virtio/mmio.rs:48-71`）：

```rust
pub struct MmioTransport {
    device: Arc<Mutex<dyn VirtioDevice>>,
    features_select: u32,
    acked_features_select: u32,
    queue_select: u32,
    device_status: u32,
    ...
}
```

设备种类：net / block / vsock / balloon / rng（`src/vmm/src/devices/virtio/` 下各子目录）。virtio 寄存器读写经维度 13 的 MMIO 总线进入 `MmioTransport::read/write`。

### 16) 网络后端 TAP/TUN — `open("/dev/net/tun")` + `TUNSETIFF` [libc + Linux ioctl]

`Tap::open_named`（`src/vmm/src/devices/virtio/net/tap.rs:120-148`）：

```rust
let fd = unsafe {
    libc::open(b"/dev/net/tun\0".as_ptr().cast::<c_char>(),
               libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC)
};
...
let ifreq = IfReqBuilder::new()
    .if_name(&terminated_if_name)
    .flags(i16::try_from(gen::IFF_TAP | gen::IFF_NO_PI | gen::IFF_VNET_HDR).unwrap())
    .execute(&tuntap, TUNSETIFF())   // ioctl TUNSETIFF
```

关键 ioctl 常量（`tap.rs:41-43`）：`TUNSETIFF` / `TUNSETOFFLOAD` / `TUNSETVNETHDRSZ`。收发经 `read/write` 该 tap fd。

### 17) 块设备后端 — 文件引擎 `pread/pwrite` (Sync) 或 io_uring (Async) [FC 自实现 + libc]

Firecracker 自实现块后端，两种引擎（`devices/virtio/block/virtio/io/mod.rs:52` `enum FileEngine`）。同步引擎 `SyncFileEngine`（`devices/virtio/block/virtio/io/sync_io.rs:46-74`）：

```rust
pub fn write(&mut self, offset, mem, addr, count, ...) -> ... {
    ...
    self.file.seek(SeekFrom::Start(offset))          // lseek
        .and_then(|slice| Ok(self.file.write_all_volatile(&slice)?))   // write(2)
    ...
}
```

异步引擎用 io_uring（`AsyncFileEngine`，`io/async_io.rs`），另可选 vhost-user-blk（`block/vhost_user/`）。后端是普通文件/块设备 fd。

### 18) 设备模拟位置 [分歧] — 用户态进程内，per-VMM `Bus` [FC 自实现]

分歧点：Firecracker **在 VMM 用户态进程内模拟所有 virtio 设备**（`peripherals.bus`，`vcpu/mod.rs:528`），不在内核、不在独立进程（vhost-user 是可选例外）。设备注册进 `MmioDeviceManager`（`device_manager/mmio.rs:181`），运行在设备工作线程 + epoll 事件循环中，与 vCPU 线程通过 eventfd/irqfd 解耦。中断控制器（IRQCHIP/PIT）则相反——放在**内核**（见维度 4）。


## 维度 4：中断与事件

### 19) LAPIC 模拟 — `KVM_CREATE_IRQCHIP`（内核 in-kernel LAPIC）[KVM 代理]

Firecracker **不在用户态模拟 LAPIC**，直接用内核 in-kernel irqchip（含每 vCPU LAPIC）。创建见 `src/vmm/src/vstate/vm.rs:385-386`：

```rust
pub fn setup_irqchip(&self) -> Result<(), VmError> {
    self.fd.create_irq_chip().map_err(VmError::VmSetup)?;   // ioctl KVM_CREATE_IRQCHIP
    ...
}
```

`KVM_CAP_IRQCHIP` 在默认能力集中（`vm.rs:329`）。LAPIC 寄存器/APIC 状态由内核维护，snapshot 时经 `KVM_GET_LAPIC/SET_LAPIC`（kvm-ioctls，此参考树 x86_64 vcpu save/restore 中）。

### 20) IOAPIC 模拟 — 同随 `KVM_CREATE_IRQCHIP`（内核 IOAPIC + PIC）[KVM 代理]

x86 的 `KVM_CREATE_IRQCHIP` 一次性创建 in-kernel PIC + IOAPIC + LAPIC。Firecracker 无独立 IOAPIC 用户态代码。GSI→IRQ 由内核 irqchip 直接处理（Firecracker 不使用 `KVM_SET_GSI_ROUTING`）。此外为避免早期 speaker 端口 exit，还建了 PIT2（`vm.rs:389-393`）：

```rust
let pit_config = kvm_pit_config { flags: KVM_PIT_SPEAKER_DUMMY, ..Default::default() };
self.fd.create_pit2(pit_config).map_err(VmError::VmSetup)   // ioctl KVM_CREATE_PIT2
```

### 21) 中断注入 — `KVM_IRQFD` + eventfd write [KVM 代理 + FC 自实现触发]

设备侧写一个 eventfd，内核自动向 guest 注入 IRQ。irqfd 绑定见 `device_manager/mmio.rs:204-208`：

```rust
vm.register_irqfd(
    &locked_device.interrupt_trigger().irq_evt,   // 该设备的 EventFd
    device_info.irqs[0],                          // GSI 线号
).map_err(MmioError::RegisterIrqFd)?;             // ioctl KVM_IRQFD
```

Firecracker 侧触发（`devices/virtio/device.rs:71-84`，`IrqTrigger::trigger_irq`）：

```rust
self.irq_status.fetch_or(irq, Ordering::SeqCst);
self.irq_evt.write(1).map_err(...)?;   // 写 eventfd → 内核经 irqfd 注入中断
```

即 Firecracker 只负责"写 eventfd"，实际中断注入语义由 KVM 内核完成（无 `KVM_INTERRUPT`/`KVM_SIGNAL_MSI` 用户态注入）。

### 22) 中断通知路径 [分歧] — irqfd 旁路，绕过 VMM 用户态 [KVM 代理]

分歧点：Firecracker 的中断路径是 **设备线程 → write(eventfd) → 内核 irqfd → guest LAPIC**，vCPU 线程和主循环**不参与**中断投递（异步旁路）。这与"VM exit 回用户态再注入"的路径不同。反方向的 I/O 通知（guest→设备）走 ioeventfd（维度 14）。`EINTR`/kick 信号（`vcpu/mod.rs:501`）只用于打断 `KVM_RUN`，不是中断投递本身。


## 维度 5：时钟与定时器

### 23) TSC 虚拟化 — `KVM_{GET,SET}_TSC_KHZ`（+ `KVM_{GET,SET}_CLOCK`）[KVM 代理]

TSC 频率的读/写用于 snapshot 迁移后的校准。`KvmVcpu::set_tsc_khz`（`vcpu/x86_64.rs:564-566`）：

```rust
pub fn set_tsc_khz(&self, tsc_freq: u32) -> Result<(), SetTscError> {
    self.fd.set_tsc_khz(tsc_freq).map_err(SetTscError)   // ioctl KVM_SET_TSC_KHZ
}
```

读取 `get_tsc_khz`（`x86_64.rs:270-271`，ioctl `KVM_GET_TSC_KHZ`）。kvmclock 状态用 `KVM_GET_CLOCK/SET_CLOCK`（`vstate/vm.rs:370` `set_clock`、`vm.rs:400` `get_clock`）。TSC 偏移/缩放实现在内核；Firecracker 只搬运频率与 clock 快照。

### 24) 高精度定时器源 timerfd — `timerfd_create` (via `timerfd` crate) [libc/syscall]

Firecracker 用 `timerfd` crate 封装 `timerfd_create/settime`，接入 epoll。速率限制器 `src/vmm/src/rate_limiter/mod.rs:370`：

```rust
let timer_fd = TimerFd::new_custom(ClockId::Monotonic, true, true)?;   // timerfd_create(CLOCK_MONOTONIC)
...
fn activate_timer(&mut self, timer_state: TimerState) {
    self.timer_fd.set_state(timer_state, SetTimeFlags::Default);       // timerfd_settime
}
```

同样用于周期性 metrics 刷写（`src/firecracker/src/metrics.rs:26`，`TimerFd::new_custom(ClockId::Monotonic, ...)`）。timerfd 是 Firecracker 内部定时（限流/超时/metrics），非 guest 时钟。

### 25) 定时器设备模拟 — 内核 PIT2（无用户态 RTC/HPET）[KVM 代理]

guest 早期时钟设备用内核 PIT2（见维度 20，`vm.rs:389-393` `create_pit2`）。Firecracker **不模拟** RTC/HPET/APIC-timer 等用户态定时器设备——LAPIC timer 在内核 irqchip 内。参考树内唯一"定时设备"性质的自实现是 `devices/pseudo/boot_timer.rs`（仅用于记录 boot 时间戳的伪设备，非 guest 可编程定时器）。

### 26) 单调时间获取 — `clock_gettime(CLOCK_MONOTONIC)` [libc/syscall]

`utils::time::get_time_ns/get_time_us`（`src/utils/src/time.rs:147-157`）：

```rust
pub fn get_time_ns(clock_type: ClockType) -> u64 {
    let mut time_struct = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(clock_type.into(), &mut time_struct) };   // clock_gettime
    ...
}
```

`ClockType::Monotonic → libc::CLOCK_MONOTONIC`（`time.rs:27`）。VMM 各处（rpc_interface、metrics、boot timer）用它测量耗时。


## 维度 6：调度与同步

### 27) 每 vCPU 一线程 — `thread::Builder::spawn`（→ `pthread_create`）[libc/std + FC 自实现]

每个 vCPU 一个专用 OS 线程，进入 loop 前加载自己的 seccomp。`Vcpu::start_threaded`（`src/vmm/src/vstate/vcpu/mod.rs:257-279`）：

```rust
let vcpu_thread = thread::Builder::new()
    .name(format!("fc_vcpu {}", self.kvm_vcpu.index))
    .spawn(move || {
        let filter = &*seccomp_filter;
        self.init_thread_local_data().expect("Cannot cleanly initialize vcpu TLS.");
        barrier.wait();
        self.run(filter);   // 加载 seccomp 后进入 KVM_RUN loop
    })?;
```

`self.run`（`mod.rs:287-...`）先 `seccompiler::apply_filter` 再跑状态机。`std::thread::spawn` 底层为 `pthread_create`。

### 28) CPU 亲和性 — 参考树内未主动调用（仅在 seccomp 白名单）[未找到主动调用]

参考树中 `sched_setaffinity` 仅出现在 seccomp 系统调用表（`src/seccompiler/src/syscall_table/x86_64.rs:264` 映射号 203），即**允许**被调用；但 VMM/vCPU 代码里未见 Firecracker 自身发起 `sched_setaffinity`/`CpuSet` 绑核。结论：**Firecracker 侧不主动 pin vCPU 线程到物理核**，绑核由外部（jailer cgroup cpuset 或运维 taskset）完成。（此点修正了旧概述文档中"vcpu 线程 pin 到 host CPU"的表述。）

### 29) vCPU 休眠 / 唤醒 — kick 信号 `SIGRTMIN+0` + `immediate_exit` [libc/信号 + FC 自实现]

唤醒/打断正在 `KVM_RUN` 的 vCPU：向其线程发实时信号，处理器置 `immediate_exit`。信号处理注册 `register_kick_signal_handler`（`mod.rs:192-205`）：

```rust
extern "C" fn handle_signal(_: c_int, _: *mut siginfo_t, _: *mut c_void) {
    unsafe {
        let _ = Vcpu::run_on_thread_local(|vcpu| {
            vcpu.kvm_vcpu.fd.set_kvm_immediate_exit(1);   // 让下一/当前 KVM_RUN 立即退出
            fence(Ordering::Release);
        });
    }
}
register_signal_handler(sigrtmin() + VCPU_RTSIG_OFFSET, handle_signal)
```

发送方 `VcpuHandle::send_event`（`mod.rs:713-724`）：把事件塞进 channel 后 `self.vcpu_thread...kill(sigrtmin() + VCPU_RTSIG_OFFSET)`，触发 `EINTR`（对应维度 8）。休眠侧则由 KVM 处理 HLT / channel 阻塞等待。

### 30) 事件循环 epoll — `event-manager` crate（epoll 封装）[libc/syscall via crate]

主循环基于 epoll，由外部 `event-manager` crate 提供，Firecracker 定型（`src/vmm/src/lib.rs:157-158`）：

```rust
/// Shorthand type for the EventManager flavour used by Firecracker.
pub type EventManager = BaseEventManager<Arc<Mutex<dyn MutEventSubscriber>>>;
```

驱动微 VM 的主循环（`src/firecracker/src/main.rs:619-624`）：

```rust
loop {
    event_manager.run().expect("Failed to start the event manager");   // epoll_wait 内部
    match vmm.lock().unwrap().shutdown_exit_code() { ... }
}
```

所有设备 eventfd、API server、timerfd、vCPU exit fd 都注册进该 epoll。底层 `epoll_create1/ctl/wait` 由 crate 封装。

### 31) 锁原语 — `std::sync::{Mutex, Arc, Barrier}` + 原子 [FC 自实现/std]

VMM 内部同步全部用 Rust 标准库原语，无自定义内核锁：
- 设备/VMM 共享态 `Arc<Mutex<...>>`（如 `main.rs:625` `vmm.lock().unwrap()`；`lib.rs:158` `Arc<Mutex<dyn MutEventSubscriber>>`）。
- vCPU 线程启动同步 `Arc<Barrier>`（`vcpu/mod.rs:260,271` `barrier.wait()`）。
- 中断状态用原子 `Arc<AtomicU32>`（`devices/virtio/device.rs:59,76` `irq_status.fetch_or(...)`）。
- vCPU↔控制线程用 `std::sync::mpsc::channel`（`vcpu/mod.rs:216` `channel()`）。

底层为 futex，但 Firecracker 侧只用 std 抽象。

### 32) 抢占通知 [可选] — 参考树内未实现 [未找到]

未见 KVM preempt-notifier 用户态对接或 PV steal-time/preempt 相关代码。抢占由宿主 CFS 调度器透明处理，Firecracker 不参与。**未在参考树中找到抢占通知接口。**


## 维度 7：安全与隔离

### 33) 权限检查 — jailer 的 `mknod` + `chown` + `setrlimit`（无 capability 校验）[libc/syscall]

Firecracker 本体不做能力/权限校验；jailer 在启动阶段做资源限制与所有权控制。文件大小/fd 数上限 `resource_limits.rs:93-101 install` + `set_limit`（`resource_limits.rs:105-112`）：

```rust
let rlim: libc::rlimit = libc::rlimit { rlim_cur: size, rlim_max: size };
SyscallReturnCode(unsafe { libc::setrlimit(resource.into(), &rlim) })   // setrlimit RLIMIT_FSIZE / RLIMIT_NOFILE
```

设备节点所有权移交给非特权 uid/gid（`env.rs:430` `libc::chown(dev_path, self.uid(), self.gid())`）。权限模型靠 chroot + uid 降权 + rlimit，而非运行时 capability 检查。

### 34) 进程沙箱 seccomp / jailer — `prctl(PR_SET_SECCOMP)` + `clone(CLONE_NEW*)` + `chroot`/`pivot_root` [libc/syscall + FC 自实现编译器]

两层沙箱。(a) seccomp-bpf：每 vCPU/线程加载 BPF filter，`seccompiler::apply_filter`（`src/seccompiler/src/lib.rs:99-121`）：

```rust
let rc = libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);   // 先禁提权
...
let bpf_prog = sock_fprog { len: bpf_filter_len, filter: bpf_filter.as_ptr() };
let rc = libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, bpf_prog_ptr);   // 装 filter
```

调用点在 vCPU 线程入口 `vcpu/mod.rs:292` `seccompiler::apply_filter(seccomp_filter)`。BPF 由 Firecracker 自研 `seccompiler` crate 从 JSON 策略编译。

(b) jailer 命名空间隔离：`clone(CLONE_NEWPID)`（`src/jailer/src/env.rs:85-98` 的 `clone` 封装 + `env.rs:355` 调用）：

```rust
libc::syscall(libc::SYS_clone, flags, child_stack, 0, 0, 0)   // SYS_clone(CLONE_NEWPID)
```

网络命名空间用 `setns(..., CLONE_NEWNET)`（`env.rs:489`）。chroot 加固用 mount namespace + `pivot_root` + `chroot`（`src/jailer/src/chroot.rs:19,54`，`libc::chroot` + `libc::chdir`）。

### 35) 资源限制 — cgroup v1/v2 + `setrlimit` [libc/syscall + cgroupfs 写入]

cgroup 通过写 cgroupfs 文件配置（`src/jailer/src/cgroup.rs`，`CgroupConfigurationBuilder`；`env.rs:210-246` 组装），把 Firecracker 进程 CPU/内存/IO 纳管；v2 统一层级下将进程写入 `cgroup.procs`（`env.rs:237-238`）。进程级 `setrlimit`（见维度 33，`resource_limits.rs:112`）限制 fd 数与文件大小。

### 36) 设备访问控制 — jailer `mknod` 白名单化设备节点 + `chown` [libc/syscall]

jailer 在 chroot 内**只创建必需的设备节点**，即设备访问白名单。`mknod_and_own_dev`（`src/jailer/src/env.rs:405-430`）：

```rust
libc::mknod(
    dev_path.as_ptr(),
    libc::S_IFCHR | libc::S_IRUSR | libc::S_IWUSR,   // 字符设备，仅 owner 读写
    libc::makedev(dev_major, dev_minor),
)
...
libc::chown(dev_path.as_ptr(), self.uid(), self.gid())
```

调用点（`env.rs:642-661`）只建 `/dev/net/tun`、`/dev/kvm`、`/dev/urandom`、（可选）`/dev/userfaultfd`。guest 看不到其他宿主设备——这就是 Firecracker 的设备访问控制机制（白名单 + owner-only 权限 + 降权 uid）。

---

## 汇总统计

按实现归属分类 36 个接口：

| 类别 | 数量 | 接口编号 |
|------|------|---------|
| KVM ioctl 代理（内核实现，FC 发起 ioctl） | 13 | 1(注册部分)、3、4(内核日志)、6、7、8、9、10、11、19、20、21、23 |
| Firecracker 自实现（用户态 Rust） | 14 | 1(mmap 分配)、4(用户态 bitmap)、12、13(总线派发)、15、17、18、31、33、34(seccompiler)、35(cgroup)、36、30(定型)、22(路径设计) |
| libc/直接 syscall | 15 | 1(mmap)、5(madvise)、14(eventfd)、16(open/ioctl TAP)、17(pread/pwrite)、24(timerfd)、26(clock_gettime)、27(pthread)、29(signal)、33/34/35/36(jailer 各 syscall) |
| 未找到 / FC 侧不实现 | 4 | 2(页面锁定)、5(MMU 反向通知)、28(CPU 亲和性未主动调用)、32(抢占通知) |

说明：多数接口同时跨类别（如接口 1 内存分配 = mmap[syscall] + set_user_memory_region[ioctl]，接口 14 = eventfd[syscall] + KVM_IOEVENTFD[ioctl]），上表按"该接口最主要的实现归属"归类，故合计与 36 不完全对应。

粗口径结论：
- **经 KVM ioctl 代理**约 13 项（vCPU 执行、寄存器/CPUID/MSR、内存注册、脏页、LAPIC/IOAPIC、中断注入、TSC）——这些是"必须内核 KVM 提供"的能力。
- **Firecracker 自实现**约 14 项（virtio 全栈、MMIO 总线派发、VM exit 分发、事件循环定型、seccomp 编译、cgroup、设备白名单）——用户态 VMM 的价值所在。
- **纯 libc/syscall** 约 15 项（mmap、eventfd、TAP、块 I/O、timerfd、clock_gettime、线程/信号、jailer 隔离链）。
- **未找到 / FC 侧不做** 4 项：页面锁定（用 MAP_NORESERVE 按需缺页，反其道）、MMU 反向通知（内核机制，无用户态对接）、CPU 亲和性（仅 seccomp 白名单允许，代码未主动绑核）、抢占通知（交给宿主 CFS）。

> 关键洞察：Firecracker 把"接近硬件"的能力全部下沉给 KVM（省去自己实现 CPU/中断/内存虚拟化），把价值集中在 **用户态设备模型 + 极简安全边界**（seccomp per-thread + jailer namespace/chroot/cgroup/mknod 白名单）。这是三者交集分析里"用户态 VMM 对 OS 的真实依赖面"的样本。

