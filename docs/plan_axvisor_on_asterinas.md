# Axvisor 移植到 Asterinas 最快速径方案

## Goal Description

以最快速度将 TGoskits 的 **axvisor**（当前运行在 ArceOS unikernel 上的 Type-I Hypervisor，已支持 RISC-V）
在 **Asterinas**（Rust 框内核 OS）上跑起来。

**核心策略**：在 Asterinas 侧新建一个 **中间适配层（`asterinas-vmm-shim`）**，但不再把问题简化成
“实现 `axvisor_api` 五类 trait”。

完整 Axvisor 运行实际依赖三层 substrate：

1. `host substrate`
2. `runtime substrate`
3. `native hypervisor substrate`

因此中间层要做的不是单层 trait glue，而是把 Asterinas OSTD/内核能力按这三层重新收口，再向上提供
Axvisor 可消费的统一 contract。

**中间层定位**：`asterinas-vmm-shim` 是一个 Rust crate，编译进 Asterinas 内核。
它对上暴露 Axvisor 所需的三层 contract，对下调用 OSTD 与内核已有设施。
它应尽量不引入新的 unsafe 代码；如必须补齐 world switch / HS trap / CSR 上下文等能力，也应收敛在最小边界内。

**研究范围界定**：
- 目标架构：**RISC-V**（H-extension，含 AIA 中断架构）
- 策略：最快速径，但按 **三层依赖** 推进，不再只按“五类 trait”推进
- 核心交付物：中间层 crate 源码 + 接口函数实现 + QEMU 原型验证
- 不包含：全 10 语义、多架构支持、设备模拟适配、性能优化

## 三层依赖模型

### 第 1 层：Host Substrate

这一层对应 ArceOS 的：

- `axalloc`
- `axhal` 中的内存、timer、IRQ、CSR/MSR 原语、地址空间/页表原语
- 控制台/UART
- SBI firmware 对接

在 Asterinas 侧，应收口成：

- 物理内存分配、连续内存、HVA/HPA 转换
- timer / clock source
- 本地中断、IPI、trap 入口辅助
- 平台初始化、CSR/MSR/H 扩展寄存器原语
- 基础 I/O 和镜像加载辅助

### 第 2 层：Runtime Substrate

这一层对应 ArceOS 的：

- `axtask`
- `axruntime`
- `.percpu`
- `KernelGuardIf`
- `SpinNoIrq`
- 早期初始化顺序

在 Asterinas 侧，应收口成：

- vCPU 执行上下文
- 调度/唤醒/暂停/绑核
- per-CPU 数据区与启动顺序
- guard 体系和 irq-save 语义
- Axvisor runtime 所依赖的 shell / waitqueue / task glue

### 第 3 层：Native Hypervisor Substrate

这一层对应：

- world switch
- HS trap
- G-stage
- 虚拟中断
- guest CSR 状态
- VM/vCPU 生命周期

在 Asterinas 侧，应收口成：

- VM create/destroy
- vCPU create/destroy
- guest memory backing + G-stage 映射
- VM entry / VM exit / exit reason
- guest CSR/GPR/FPR 上下文
- 虚拟 timer / 虚拟中断 / VMID / HFENCE.GVMA

> 这三层里，`axvisor_api` 的五类 trait 最多只覆盖了第 1 层的一部分和第 2 层的一小部分，
> 不能代表 Axvisor 完整运行依赖。

**接口语义模型（结论复用）**：

不可约减的 5 个最小语义：
1. **物理内存钉住** — `pin_memory(addr, len) → phys_addr[]`
2. **vCPU 执行循环** — `vcpu_run(vcpu_id) → exit_reason, exit_info`
3. **中断注入** — `inject_interrupt(vcpu_id, vector, type)`
4. **I/O 拦截与转发** — `trap_mmio(gpa, len, dir, data)` / `trap_pio(port, len, dir, data)`
5. **定时器源** — `timer_set(deadline_ns, callback)`

完整交集的额外 5 个语义：
6. **VM/vCPU 生命周期管理** — create/destroy VM, create/destroy vCPU
7. **寄存器访问** — get/set vCPU general/special registers
8. **时间基准虚拟化** — Guest 可见时间 CSR 的 offset/scaling（RISC-V `htimedelta`）
9. **vCPU 调度抽象** — vCPU 绑核、Host 调度通知
10. **设备节点/访问控制** — 权限受控的虚拟化能力入口

## Asterinas 中间层（`asterinas-vmm-shim`）接口清单

这是本次最快速径计划的核心交付物。中间层将 Asterinas OSTD 的底层能力包装为 axvisor 所需的语义接口，
每个接口对应一个具体的 Rust 函数。

### 架构位置

```
axvisor VMM 逻辑 (不变)
  │ 调用 axvisor_api trait 方法
  ▼
asterinas-vmm-shim (NEW — 本次实现)
  │ 实现 axvisor_api trait
  │ 包装 OSTD 硬件抽象
  ▼
Asterinas OSTD (复用现有能力 + 少量扩展)
  ├─ ostd::mm        — 物理内存分配/映射
  ├─ ostd::arch::riscv — RISC-V CSR 读写 (需新增 H-extension CSR)
  ├─ ostd::task      — 任务调度 (vCPU 线程)
  ├─ ostd::timer     — 高精度定时器
  └─ ostd::intr      — 中断框架 (需扩展虚拟中断)
```

### 接口函数清单（7 类，共 17 个函数）

#### 第 1 类：物理内存钉住 & Guest 内存映射 — 4 个函数

```rust
/// 将一段 Host 虚拟地址区间钉住到物理内存，返回物理地址列表。
/// 调用时机：VM 初始化时，为 Guest 分配物理内存。
/// 对应语义 #1
pub fn hyp_pin_memory(vaddr: *const u8, len: usize) -> Result<Vec<PhysAddr>, HypError>;

/// 解除钉住，释放物理页。
pub fn hyp_unpin_memory(vaddr: *const u8, len: usize) -> Result<(), HypError>;

/// 将虚拟地址翻译为物理地址（页粒度）。
pub fn hyp_virt_to_phys(vaddr: *const u8) -> Result<PhysAddr, HypError>;

/// 将一段 Guest 物理地址映射到 Host 物理地址，构建 G-stage 页表项。
/// 这是执行 Guest 指令的前置条件——没有 G-stage 映射，第一条取指就 guest-page-fault。
/// 调用时机：hyp_pin_memory 之后、hyp_vcpu_run 之前。
/// perms: R | W | X 的组合
/// G-stage leaf PTE 需要额外置位：V=1, U=1（G-stage 按"类似 U-mode"检查权限）、
///   A=1, D=1（对可写页，否则第一条 store 就 fault）
pub fn hyp_map_guest_memory(vm: &VmHandle, gpa: u64, hpa: u64, len: u64, perms: u8)
    -> Result<(), HypError>;
```

**OSTD 依赖**：
- `ostd::mm::allocate_contiguous()` → 物理页
- `ostd::arch::riscv::satp` → 页表 walk
- `ostd::arch::riscv::hypext` → `hgatp` CSR 写入 + `HFENCE.GVMA` 刷新 TLB
- G-stage 页表需要从 OSTD 的页表分配器分配 root page（16 KiB 对齐，RISC-V 规范要求）
- G-stage leaf PTE 格式：`V=1 | U=1 | A=1 | D=1 | R/W/X perms | PPN`（若硬件不支持 A/D 自动更新，需软件置位或实现 A/D fault 补页逻辑）

#### 第 2 类：VM/vCPU 生命周期 — 4 个函数

```rust
/// 创建一个空 VM 实例，返回句柄。
/// 对应语义 #6
pub fn hyp_vm_create() -> Result<VmHandle, HypError>;

/// 销毁 VM 及其所有资源。
pub fn hyp_vm_destroy(vm: VmHandle) -> Result<(), HypError>;

/// 在给定 VM 中创建一个 vCPU。
/// 对应语义 #6
pub fn hyp_vcpu_create(vm: &VmHandle, cpu_id: usize) -> Result<VcpuHandle, HypError>;

/// 销毁 vCPU。
pub fn hyp_vcpu_destroy(vcpu: VcpuHandle) -> Result<(), HypError>;
```

**OSTD 依赖**：`ostd::task::spawn()` — 为每个 vCPU 创建执行上下文

#### 第 3 类：vCPU 执行循环 — 1 个函数（最核心）

```rust
/// 进入 Guest 模式执行，发生 VM Exit 时返回退出原因和相关信息。
/// 这是整个中间层的最核心函数，封装了 RISC-V H-extension 的 Guest 进入/退出流程。
/// 对应语义 #2
pub fn hyp_vcpu_run(vcpu: &VcpuHandle) -> Result<ExitReason, HypError>;
```

**内部流程**：
1. 保存 Host 上下文（`stvec`、`sepc`、`sstatus`、`scause`、`stval`），设置 HS trap vector 指向 VM Exit 汇编入口
2. 从 `VcpuHandle` 恢复 Guest 通用寄存器（GPR x0-x31）+ VS 级 CSR 上下文（`vsstatus`、`vsie`、`vstvec`、`vsscratch`、`vsepc`、`vscause`、`vstval`、`vsatp`）
3. 将 vCPU 的 **run PC 字段**（由 `hyp_vcpu_set_reg(Pc, entry)` 写入）加载到 HS `sepc`
   - 注意：`Pc` ≠ `vsepc`。`vsepc` 是 guest 在 VS-mode 内部 trap 时使用的虚拟 supervisor epc，不是 VM entry 的跳转目标
   - `SRET` 从 HS-mode 进入 VS-mode 时，跳转地址来自 HS `sepc`，而非 `vsepc`
4. 配置 `hstatus.SPV = 1`（SRET 后 V=1，进入虚拟模式）+ **`sstatus.SPP = 1`**（nominal privilege = Supervisor，进入 VS 而非 VU）
   - 注意：`SPP` 在 HS 级 `sstatus` 中，不是 `hstatus` 的字段；`SPVP` 影响 HLV/HSV 指令的有效权限等级，不是选择 SRET 目标模式的位
5. 配置 `hedeleg`：**选择性委托** — VU ecall 委托给 VS（作为 guest 用户态 syscall），VS ecall **不委托**（作为 hypercall/VM Exit）；guest-page-fault、virtual-instruction 不委托
6. 配置 `hideleg`：委托 VS-level timer/software interrupt 给 guest（注入虚拟中断时需要 `hideleg` 对应位=1）；Host 真实外部中断不委托，先进 HS
7. 配置 `hgatp`：指向 G-stage 页表（VS-stage 翻译后的 GPA → HPA），页表格式与 Host 使用的 Sv39/Sv48 一致，含 VMID
8. 写 `hcounteren`：使能 Guest 可见的计数器（`TM`/`CY`/`IR` 位）
9. 执行 `SRET` → VS-mode → Guest 开始执行
10. VM Exit 发生时，汇编入口保存 Guest GPR，读 `scause`/`sepc`/`stval`/`htval`/`htinst`/`hstatus`，恢复 Host 上下文
11. 将 HS `sepc` 保存为 vCPU 的 run PC 字段（用于 resume），将 GPR + VS CSR 保存到 `VcpuHandle`，返回 `ExitReason`
12. 执行 `HFENCE.GVMA` 刷新 G-stage TLB（在修改 `hgatp` 或 G-stage 页表后必须执行）

**OSTD 依赖**：新增 `ostd::arch::riscv::hypext` 模块（见 M1-Phase B），封装以下 CSR 和指令：
- **模式切换**：`hstatus`（R/W: SPV, SPVP, VGEIN 字段；注意 SPV 控制 SRET 后 V 位）、`sstatus`（HS 级，R/W: SPP 字段——决定 SRET 后进入 Supervisor 还是 User）、`vsstatus`（R/W: SPP, SIE, SUM 等）
- **Trap 委托**：`hedeleg`（W，按位选择性委托异常：VU ecall=委托给 VS 当 guest syscall，VS ecall=不委托当 hypercall）、`hideleg`（W，按位选择性委托中断：bit 10/6/2 分别对应 VSEIP/VSTIP/VSSIP，注入虚拟外部中断时需设 bit 10=1 使 guest 能接收）
- **G-stage 地址翻译**：`hgatp`（W: MODE + PPN）、VS-stage `vsatp`（R/W: Guest 可见的 satp）
- **VM Exit 信息**：`htval`（R: GPA 或指令编码）、`htinst`（R: transformed/原始指令）、`hstatus`（R: 退出时的 SPV）
- **计数器使能**：`hcounteren`（W: TM/CY/IR 位）
- **虚拟中断**：`hvip`（R/W: VSEIP/VSTIP/VSSIP）、`hie`（R/W: 虚拟中断使能）、`hip`（R: hypervisor interrupt pending 查询）、`vsip`（VS interrupt pending，由 `hvip`/`hip` 派生，需纳入 vCPU 上下文）
- **配置控制**：`henvcfg`/`henvcfgh`（W: FIOM/PBMTE/ADUE 等 guest 行为控制位）
- **时间虚拟化**：`htimedelta`（W: Guest time CSR 的 delta 值）、`vstimecmp`/`vstimecmph`（若使用 Sstc 扩展虚拟化 timer，需纳入 vCPU 上下文）
- **Guest 外部中断**：`hgeie`（W: per-guest external interrupt enable）、`hgeip`（R: pending）、`hstatus.VGEIN`（若使用 AIA guest external interrupt，必须管理）
- **VMID**：需要分配 VMID（写入 `hgatp` 的 VMID 字段），VMID 宽度是 WARL（需 probe，不可假设 `u16` 全可用），可能为 0
- **TLB 管理**：`HFENCE.GVMA` 指令（G-stage TLB 刷新，修改 `hgatp` 或 G-stage 页表后必须执行，需在运行 vCPU 的 hart 上执行）
- **HS trap vector + world switch**：Host `stvec` 需指向 HS-mode VM Exit **汇编入口**（必须用 naked asm 保存全部 Guest GPR 后才能进入 Rust；普通 Rust 函数不能承担 SRET 前后的寄存器约定）
- **vCPU 上下文**：`VcpuHandle` 内保存：run PC 字段（VM entry 用）+ GPR x0-x31 + FPR f0-f31 + 完整 VS 级 CSR 上下文（`vsstatus/vsie/vstvec/vsscratch/vsepc/vscause/vstval/vsatp/vsip`）

#### 第 4 类：寄存器访问 — 2 个函数

```rust
/// 读取 vCPU 的指定寄存器（通用 / CSR / FPU）。
/// 对应语义 #7
pub fn hyp_vcpu_get_reg(vcpu: &VcpuHandle, reg: RegId) -> Result<u64, HypError>;

/// 写入 vCPU 的指定寄存器。
pub fn hyp_vcpu_set_reg(vcpu: &VcpuHandle, reg: RegId, val: u64) -> Result<(), HypError>;
```

**RegId 枚举**：`Gpr(u8)` | `Csr(u16)` | `Fpr(u8)` | `Pc`（读写 vCPU 的 run PC 字段；VM entry 时加载到 HS `sepc`；VM exit 后从 HS `sepc` 保存回 run PC；非硬件 `vsepc`）
**OSTD 依赖**：`VcpuHandle` 内部保存寄存器上下文：run PC + GPR x0-x31 + FPR f0-f31 + VS 级 CSR

#### 第 5 类：中断注入 — 2 个函数

```rust
/// 向指定 vCPU 注入中断/异常。
/// 对应语义 #3
/// - vector: RISC-V 异常/中断编号（如 5 = Supervisor Timer Interrupt）
/// - int_type: ExternalInterrupt / SupervisorInterrupt / Exception
pub fn hyp_inject_interrupt(vcpu: &VcpuHandle, vector: u32, int_type: InterruptType)
    -> Result<(), HypError>;

/// 设置虚拟 IRQ 线电平（用于设备模拟向 vCPU 发信号）。
pub fn hyp_set_irq_line(vm: &VmHandle, irq: u32, level: bool) -> Result<(), HypError>;
```

**OSTD 依赖**：
- `hvip` CSR（设置 VSEIP/VSTIP/VSSIP 位触发虚拟中断）：注意注入虚拟外部中断（VSEIP）时需同时设 `hideleg[10]=1`，否则 guest 无法接收——注入路径是 HS 设 `hvip.VSEIP`，guest 通过 `hideleg` 委托后由 `vsie.SEIE`/`vsstatus.SIE` 控制接收
- `hie` CSR（虚拟中断使能）、`hip` CSR（interrupt pending 查询）
- `hgeie` / `hgeip` / `hstatus.VGEIN`（AIA Guest 外部中断管理）

#### 第 6 类：I/O 拦截 — 2 个函数

```rust
/// 处理 Guest MMIO 读退出：从指定 GPA 读取 len 字节。
/// 对应语义 #4（RISC-V 无 PIO，仅 MMIO）
/// 调用时机：vcpu_run 返回 ExitReason::MmioRead { gpa, len } 时
pub fn hyp_handle_mmio_read(gpa: u64, len: u8) -> Result<u64, HypError>;

/// 处理 Guest MMIO 写退出：向指定 GPA 写入 len 字节数据。
pub fn hyp_handle_mmio_write(gpa: u64, len: u8, data: u64) -> Result<(), HypError>;
```

**OSTD 依赖**：维护 memory slot / device region 表（未映射 MMIO 通过 guest-page-fault 退出，不通过 G-stage 页表逆查；需用 `htval` 获取 GPA、`htinst` 解析访问宽度和寄存器）

#### 第 7 类：定时器源 — 2 个函数

```rust
/// 设置一个单次触发的高精度定时器，到期时触发回调。
/// 对应语义 #5
/// 回调用于向 Guest 注入定时器中断（通过 hyp_inject_interrupt 实现）
pub fn hyp_timer_set(deadline_ns: u64, callback: fn(&VcpuHandle)) -> Result<TimerHandle, HypError>;

/// 取消指定定时器。
pub fn hyp_timer_cancel(timer: TimerHandle) -> Result<(), HypError>;
```

**OSTD 依赖**：`ostd::timer` 提供高精度定时器（通过 `stimecmp` / SBI Timer 或硬件 timer）

### 辅助类型定义

```rust
/// 句柄类型 — 使用 Arc 包装内部状态，避免 use-after-destroy 和跨 VM vCPU 混用
/// 或用 generation-based 索引（handle = index + generation），中间层维护全局表
pub struct VmHandle(Arc<VmInner>);
pub struct VcpuHandle(Arc<VcpuInner>);
pub struct TimerHandle(usize);   // Timer ID（轻量，一次性的）
pub type PhysAddr = u64;         // 物理地址
pub type VmId = u16;             // VMID（写入 hgatp.VMID 字段）

/// VM Exit 原因枚举（RISC-V 语义）
pub enum ExitReason {
    /// MMIO 读退出 — 需包含指令元数据以便设备模拟推进 PC 和处理符号扩展
    MmioRead  {
        gpa: u64,
        len: u8,
        target_reg: RegId,      // 加载目标寄存器
        sign_extend: bool,       // 是否需要符号扩展
        insn_len: u8,            // 指令长度 (2 或 4 字节，压缩指令时 2)
    },
    /// MMIO 写退出
    MmioWrite {
        gpa: u64,
        len: u8,
        data: u64,
        insn_len: u8,            // 指令长度，用于 PC advance
    },
    /// VS-mode ecall 未被 hedeleg 委托，触发 VM Exit 到 HS
    EcallFromVs,
    /// Hypervisor ecall (Guest 发出的 hypercall)
    EcallFromVU,
    /// 中断请求（外部中断 pending，由 hvip/hgeip 指示）
    InterruptRequested { cause: u64 },
    /// Guest 页错误（G-stage 缺页）
    GuestPageFault { gpa: u64, cause: u64 },
    /// 虚拟指令异常（Guest 执行了需要在 HS 模拟的指令）
    VirtualInstruction { insn: u32 },
    /// 关机请求
    Shutdown,
    /// VM Entry 失败
    FailEntry { error: VmEntryError },
}

pub enum InterruptType {
    ExternalInterrupt,   // SEI — 由 hvip.VSEIP 触发
    SupervisorInterrupt, // VSSI — 由 hvip.VSSIP 触发
    Exception,           // 同步异常
}

pub enum HypError {
    InvalidHandle,
    InvalidAddress,
    NoMemory,
    VcpuBusy,             // vCPU 正在执行中
    InvalidState,         // 操作与当前状态不兼容（如 map_memory 在 vcpu_run 之后）
    AlreadyMapped,        // GPA 已有映射
    NotMapped,            // GPA 未映射（MMIO 处理时）
    GuestPageFault,       // G-stage 缺页
    PermissionDenied,     // 权限不足
    UnsupportedCsr(u16),  // 不支持的 CSR 编号
    WouldBlock,           // 操作会阻塞（如 vcpu_run 时 vCPU 未就绪）
    OstdError(i32),       // 底层 OSTD 错误传递
    NotSupported,         // 功能不支持
}

pub enum RegId {
    Gpr(u8),   // x0-x31
    Csr(u16),  // 标准 CSR 编号
    Fpr(u8),   // f0-f31
    Pc,        // sepc
}
```

### 函数依赖关系（拓扑序）

```
第 1 步: hyp_vm_create()          → 创建 VmHandle
第 2 步: hyp_pin_memory()         → 分配 Guest 物理内存
第 3 步: hyp_vcpu_create()        → 创建 vCPU，分配 VS-stage 上下文
第 4 步: hyp_vcpu_set_reg()       → 设置 Guest 初始寄存器（PC、a0、a1）
第 5 步: hyp_timer_set()          → (可选) 设置 Guest 定时中断
第 6 步: hyp_vcpu_run()           → 进入 Guest ← 核心循环
  ├─ 退出时：match ExitReason
  ├─ MmioRead/Write → hyp_handle_mmio_read/write()
  ├─ InterruptRequested → hyp_inject_interrupt()
  └─ TimerExpired → hyp_timer_set() 重置
回到第 6 步（循环）
```

### 最快速径裁剪：只需实现 6 个核心能力即可跑通最小闭环

最小启动 Guest 需要（修复 Codex 指出的缺失项）：

| 能力 | 对应函数 | 用途 |
|------|---------|------|
| 创建 VM | `hyp_vm_create()` | 分配 VM 内部结构 + VMID |
| 分配 Guest 物理内存 | `hyp_pin_memory()` | 调用 `ostd::mm` 分配连续物理页 |
| **构建 G-stage 映射** | **`hyp_map_guest_memory()`** | **将 GPA 映射到 HPA，写 G-stage 页表——缺失此项第一条取指就 fault** |
| 创建 vCPU | `hyp_vcpu_create()` | 分配 vCPU 上下文结构体 + VS 级 CSR 初始值 |
| 设置入口 PC | `hyp_vcpu_set_reg()` | 写 vCPU run PC 字段（VM entry 前加载到 HS `sepc`，非 `vsepc`） |
| 执行 Guest | `hyp_vcpu_run()` | 配置 H-extension CSR + SRET 进入 VS-mode |

**Codex 审计结论**：原计划 5 个函数无法完成最小闭环——缺少 `hyp_map_guest_memory` 导致 G-stage 页表无映射，第一条 Guest 取指必定触发 guest-page-fault。修复后为 6 个核心能力。

其余 11 个函数按需逐步实现。

**RISC-V H-extension 关键 CSR 映射**：
- vCPU 执行：`hstatus`、`hedeleg`、`hideleg`、`hcounteren`
- VS 级上下文：`vsstatus`、`vsie`、`vstvec`、`vsscratch`、`vsepc`、`vscause`、`vstval`、`vsatp`
- 中断注入：`hvip`、`hie`、`hgeie`、`hgeip`
- 时间虚拟化：`htimedelta`（注：`htime` 不是标准 H-extension CSR，已移除）
- 二阶段地址转换：`hgatp`（含 VMID 字段，G-stage 页表 root 需 16 KiB 对齐）、`HFENCE.GVMA`
- Host trap vector：`stvec`（HS-mode VM Exit 入口）

---

## Acceptance Criteria

- AC-1: `asterinas-vmm-shim` 中间层 6 个核心能力实现完成且可编译
  - Positive Tests:
    - `hyp_vm_create()` / `hyp_pin_memory()` / `hyp_map_guest_memory()` / `hyp_vcpu_create()` / `hyp_vcpu_set_reg()` / `hyp_vcpu_run()` 共 6 个函数实现完成
    - `hyp_map_guest_memory()` 正确构建 G-stage 页表（至少支持 Sv39x4），写入 `hgatp` 后执行 `HFENCE.GVMA`
    - 每个函数有正确的签名、错误处理和内部逻辑
    - `asterinas-vmm-shim` crate 在 Asterinas 内核中编译通过（`cargo build` 无错误）
    - `hyp_vcpu_run()` 内部正确配置 `hstatus.SPV=1` + `sstatus.SPP=1`（SPP 在 HS 级 sstatus 中，非 hstatus）、`hedeleg`（VU ecall 委托给 VS，VS ecall 不委托）、`hideleg`、`hgatp`、`hcounteren`
    - HS trap vector 正确设置到 `stvec`，VM Exit 时能进入 Rust 处理
  - Negative Tests:
    - 不应引入 unsafe 代码到中间层（unsafe 全部委托给 OSTD）
    - 不应在中间层中直接写 CSR 汇编
    - `hedeleg` 不应全量委托异常——至少保留 VS ecall 和 guest-page-fault 不委托

- AC-2: 辅助类型和枚举定义完整
  - Positive Tests:
    - `VmHandle`、`VcpuHandle`、`TimerHandle`、`PhysAddr` 类型定义
    - `ExitReason`、`InterruptType`、`HypError`、`RegId` 枚举定义
    - 所有类型独立于 axvisor 和 ArceOS，无第三方耦合
  - Negative Tests:
    - 不应依赖 `axstd` 的任何类型
    - 不应依赖 `kvm-bindings` 或 Linux 特有 crate

- AC-3: Asterinas OSTD 新增 `hypext` 模块完成
  - Positive Tests:
    - `ostd::arch::riscv::hypext` 模块提供 H-extension CSR 的安全读写接口
    - 至少封装以下 CSR：`hstatus`(R/W: SPV/SPVP/VGEIN)、`sstatus`(HS 级, R/W: SPP)、`hedeleg`(W)、`hideleg`(W)、`hgatp`(W, 含 VMID 字段)、`htval`(R)、`htinst`(R)、`hvip`(R/W)、`hie`(R/W)、`hip`(R)、`htimedelta`(W)、`hcounteren`(W)、`hgeie`(W)、`hgeip`(R)、`henvcfg`/`henvcfgh`(W)
    - VS 级 CSR 上下文保存/恢复接口：`vsstatus`、`vsie`、`vstvec`、`vsscratch`、`vsepc`、`vscause`、`vstval`、`vsatp`、`vsip`
    - 提供 `hfence_gvma()` 函数（封装 `HFENCE.GVMA` 指令）用于 G-stage TLB 刷新
    - G-stage 页表 root page 从 OSTD 页表分配器分配，满足 16 KiB 对齐要求（`hgatp` 规范要求）；VMID 宽度需 probe（WARL，不可假设 `u16` 全可用）
    - HS trap vector 设置接口存在（`stvec` 写函数，指向汇编级 VM Exit 入口）
  - Negative Tests:
    - 不应在 Safe Rust 中暴露裸 CSR 写入
    - 不应占用 OSTD 现有模块的公开 API 命名空间
    - 不应包含 `htime`——该 CSR 不是标准 H-extension CSR

- AC-4: 最小闭环原型在 QEMU RISC-V 上验证通过（精确验证标准）
  - Positive Tests:
    - 环境：QEMU RISC-V virt 机器，`-cpu rv64,h=true`（启用 H-extension）
    - Asterinas 编译包含 `asterinas-vmm-shim`，在 QEMU 中启动成功
    - 调用序列：`hyp_vm_create()` → `hyp_pin_memory()` → `hyp_map_guest_memory()` → `hyp_vcpu_create()` → `hyp_vcpu_set_reg(Pc, entry)` → `hyp_vcpu_run()`
    - Guest 代码：`nop; ecall`（4 字节编码），加载到 `0x80000000`，GPA→HPA 映射到该地址
    - 验证关键点（Codex 指定）：
      - `sret` 从 HS 成功进入 VS，guest 执行 `nop`
      - `ecall from VS-mode` **未被** `hedeleg` 委托（`hedeleg[10]=0` 或默认值），触发 VM Exit 到 HS
      - HS trap handler 捕获 `scause=10`（Environment call from VS-mode）
      - 日志 dump 关键寄存器：`hstatus.SPV`、`sstatus.SPP`、`hgatp`（含 VMID）、`scause`、`vsepc`、`htval`、`htinst`
      - 返回 `ExitReason::EcallFromVs`
  - Negative Tests:
    - 不应使用 QEMU 的 KVM 加速
    - 不应链接 axvisor 代码（原型仅验证中间层 + OSTD）
    - `ecall` 不应被 Guest 自己的 `vstvec` 处理（那表示 `hedeleg[10]=1` 配置错误，VS ecall 被委托了）
    - HS `sepc` 退出后应为 `0x80000004`（ecall 地址），不是 `vsepc`（vsepc 是 guest 内部 trap 时才写的虚拟 sepc）

- AC-5: 其余 11 个函数的设计说明（不要求实现，但需有函数签名 + 实现要点注释）
  - Positive Tests:
    - `hyp_vm_destroy()` / `hyp_vcpu_destroy()` / `hyp_vcpu_get_reg()` / `hyp_unpin_memory()` / `hyp_virt_to_phys()` / `hyp_inject_interrupt()` / `hyp_set_irq_line()` / `hyp_handle_mmio_read()` / `hyp_handle_mmio_write()` / `hyp_timer_set()` / `hyp_timer_cancel()` 共 11 个函数有签名定义
    - 每个函数附带 2-3 行注释说明实现要点（依赖 OSTD 的哪个子系统，关键步骤）
  - Negative Tests:
    - 不要求完整实现代码

- AC-6: `asterinas-vmm-shim` 接口与 `axvisor_api` trait 结构对齐
  - Positive Tests:
    - `axvisor_api` 的 RISC-V 路径模块（`arch`、`host`、`memory`、`time`、`vmm`）调用清单审计完成
    - shim 的 17 个函数按 `axvisor_api` 模块分组，标注每个函数对应 axvisor_api 的哪个 trait 方法
    - 接口函数签名不产生与 axvisor_api 重复的抽象（shim 直接实现 axvisor_api trait，而非定义新的 `hyp_*` 自由函数层）
  - Negative Tests:
    - 不应在 axvisor_api 之外额外定义一套语义层的 trait（避免二次适配）

- AC-7: 最快速径评估与后续计划
  - Positive Tests:
    - 从 6 个核心函数到完整 17 个函数的工作量估算
    - axvisor 侧 axvisor_api 切换到 `asterinas-vmm-shim` 的改动评估
    - 阻塞项清单（OSTD 能力缺口、axvisor 架构假设冲突等）
    - 硬件/固件前置条件检测清单（H-extension 存在性、AIA/非-AIA 配置、QEMU 版本要求）
  - Negative Tests:
    - 不应给出无依据的工时数字

---

## Path Boundaries

### Upper Bound (Maximum Scope)

- 17 个函数全部实现（7 类接口完整）
- 中断注入（`hyp_inject_interrupt` + `hyp_set_irq_line`）与 AIA IMSIC 虚拟化打通
- MMIO 拦截完整模拟（含指令元数据：target_reg、sign_extend、insn_len 的解析）
- 定时器集成到 Asterinas 中断框架（含 `Sstc` 扩展的 `vstimecmp` 虚拟化或 SBI timer fallback）
- 在 QEMU 上启动一个最小 Linux guest 到 shell 提示符

### Lower Bound (Minimum Scope)

- 6 个核心函数实现（`hyp_vm_create` + `hyp_pin_memory` + `hyp_map_guest_memory` + `hyp_vcpu_create` + `hyp_vcpu_set_reg` + `hyp_vcpu_run`）
- `ostd::arch::riscv::hypext` 模块的完整 CSR 封装（12 个 CSR：`hstatus`、`hedeleg`、`hideleg`、`hgatp`、`hcounteren`、`htval`、`htinst`、`hvip`、`hie`、`htimedelta`、`hgeie`、`hgeip` + `HFENCE.GVMA` 指令 + VS 级 CSR 上下文 + HS trap vector 管理）
- `ExitReason`、`HypError`、`VcpuHandle`（含完整 VS CSR 上下文）等辅助类型的完整定义
- `axvisor_api` RISC-V 路径调用清单审计完成（M0 交付物）
- 在 QEMU 上执行 guest `nop; ecall`，`scause=10` 被 HS trap handler 捕获，返回 `ExitReason::EcallFromVs`
- 其余 11 个函数仅提供签名 + 实现要点注释

### Allowed Choices

- Can use:
  - RISC-V H-extension 标准 CSR 和指令
  - Asterinas OSTD 现有基础（`ostd::mm`、`ostd::task`、`ostd::timer`、`ostd::intr`）
  - QEMU RISC-V virt 平台（`-cpu rv64,h=true`）
  - Rust `riscv` crate 的寄存器定义
  - axvisor 现有代码作为参考（不链接，仅参考逻辑）
- Cannot use:
  - Linux KVM 或任何 Linux 特有机制
  - x86 概念直接映射（无 PIO、无 TSC、无 LAPIC）
  - ArceOS `axstd` crate 作为依赖
  - 需要重写 OSTD 核心框架的方案

---

## Dependencies and Sequence

### Milestones

#### M0: axvisor_api 审计 + 前置条件验证（前置分析）

- Phase A: axvisor_api 调用点审计
  - 在 axvisor TGoskits 仓库中，追踪 RISC-V 路径下所有 `axvisor_api` trait 方法调用
  - 按模块分组统计：`arch`（CSR 操作）、`host`（内存/VM）、`memory`（地址空间）、`time`（定时器）、`vmm`（VM/vCPU 生命周期）
  - 标注每个调用是否属于最快速径的 6 个核心能力之一
  - 审计结果直接决定 M2 的函数签名——shim 应实现 axvisor_api trait，而非定义独立的 `hyp_*` 自由函数层
- Phase B: 硬件/固件前置条件核对清单
  - QEMU RISC-V 版本要求（≥ 7.0，H-extension 支持）
  - H-extension CSR 存在性检测方法（`misa` 寄存器 H 位）
  - AIA/IMSIC 是否启用（影响中断注入策略）
  - OstD 当前 RISC-V 支持的成熟度摸底（哪些 CSR 已封装、页表格式、中断框架）
- Phase C: 差距矩阵速览
  - axvisor_api 所需 ↔ Asterinas OSTD 已有 ↔ 需新增
  - 重点标注阻塞项（如 OSTD 完全不支持 G-stage 页表分配）

**依赖**：axvisor TGoskits 仓库 + Asterinas 仓库源码访问
**交付物**：axvisor_api 调用清单 + 前置条件核对表 + 差距矩阵速览

#### M1: 环境搭建 + OSTD H-extension 完整扩展（基础依赖）

- Phase A: 拉取 Asterinas 源码，在 QEMU RISC-V 上启动最小内核
  - 验证 Asterinas RISC-V 基础可用性（boot + 串口输出 + 基本 `ostd::mm` 可用）
  - 验证 H-extension 可用性：通过 firmware/DTB、SBI 能力探测、或受控尝试访问 H CSR 并捕获 illegal instruction 来检测（HS/S-mode 不能直接读 M-mode CSR `misa`）
  - QEMU 参数：`-M virt -cpu rv64,h=true -m 512M`
- Phase B: 新建 `ostd::arch::riscv::hypext` 模块
  - 完整 CSR 读写封装（16 个 CSR）：
    - `hstatus`(R/W: SPV/SPVP/VGEIN)、`sstatus`(HS 级，R/W: SPP 字段)、`hedeleg`(W)、`hideleg`(W)、`hgatp`(W: MODE+VMID+PPN)、`hcounteren`(W)
    - `htval`(R)、`htinst`(R)、`hvip`(R/W: VSEIP/VSTIP/VSSIP)、`hie`(R/W)、`hip`(R)
    - `htimedelta`(W)、`henvcfg`/`henvcfgh`(W: FIOM/PBMTE/ADUE)、`hgeie`(W)、`hgeip`(R)
  - VS 级 CSR 上下文保存/恢复：`vsstatus`、`vsie`、`vstvec`、`vsscratch`、`vsepc`、`vscause`、`vstval`、`vsatp`、`vsip`
  - Timer CSR（若使用 Sstc）：`vstimecmp`/`vstimecmph` 纳入 vCPU 上下文
  - `hfence_gvma()` 函数（封装 `HFENCE.GVMA` 指令）
  - HS trap vector 管理：Host `stvec` 写函数 + **汇编级** VM Exit 入口（naked asm 保存全部 Guest GPR 后才能调用 Rust handler；普通 Rust 函数不能承担 SRET 前后的寄存器约定）
  - 格式：每个 CSR 一个 `read_*()` / `write_*()` 函数对，unsafe 代码仅在函数体内
- Phase C: 新建 `asterinas-vmm-shim` crate
  - 在 Asterinas 源码树中创建 `services/vmm-shim/` 目录
  - 配置 `Cargo.toml`（依赖 `ostd`）
  - 定义辅助类型（见接口清单中的类型定义一节）
  - 接口按 `axvisor_api` 模块分组组织（`memory`、`vmm`、`arch`、`time`），标注与 M0 审计结果的对应关系

**依赖**：M0 完成（知道 axvisor_api 需要什么）+ Asterinas RISC-V 能在 QEMU 上成功启动
**交付物**：`ostd::arch::riscv::hypext` 模块（16 CSR + HFENCE.GVMA + VS CSR context + HS trap vector 汇编入口）+ `asterinas-vmm-shim` crate 骨架 + 类型定义

#### M2: 6 个核心能力实现（最小闭环）

- Phase A: 实现 `hyp_vm_create()` + `hyp_vm_destroy()`
  - 内部分配 `VmInner`（Arc 包装，含 VMID 分配、G-stage 页表 root 16 KiB 对齐）
- Phase B: 实现 `hyp_pin_memory()` + `hyp_unpin_memory()` + `hyp_virt_to_phys()`
  - 调用 `ostd::mm` 分配连续物理页，记录 vaddr→phys 映射
- Phase C: 实现 `hyp_map_guest_memory()` — **新增关键函数**
  - 从 OSTD 页表分配器分配 G-stage 页表页
  - 逐页构建 G-stage leaf PTE：`V=1 | U=1 | A=1 | D=1 | R/W/X perms | PPN`（G-stage 按"类似 U-mode"检查权限，U/A/D 位必须置位；若硬件不支持 A/D 自动更新，需软件置位或实现 A/D fault 补页逻辑）
  - 写入 `hgatp`（含 VMID），执行 `HFENCE.GVMA`（需在运行该 vCPU 的 hart 上执行）
- Phase D: 实现 `hyp_vcpu_create()` + `hyp_vcpu_destroy()`
  - 分配 `VcpuInner`（Arc 包装，含 GPR x0-x31 + FPR f0-f31 + 完整 VS 级 CSR 上下文）
  - 设置 VS 级 CSR 默认值（`vsstatus.SIE=0`、`vstvec=0`、`vsscratch=0`、`vsatp=0` 即 VS-stage Bare）
- Phase E: 实现 `hyp_vcpu_set_reg()` + `hyp_vcpu_get_reg()`
  - 读写 `VcpuInner` 中的寄存器上下文（GPR/CSR/FPR/PC）
  - `Pc` 读写 vCPU 的 **run PC** 字段（≠ `vsepc`）。VM entry 前将此字段写入 HS `sepc`；VM exit 后从 HS `sepc` 保存回此字段
- Phase F: 实现 `hyp_vcpu_run()` — **最核心函数**
  - 从 `VcpuInner` 恢复 Guest GPR/VS CSR 上下文到物理寄存器
  - 保存 Host 上下文（`stvec`/`sepc`/`sstatus`/`scause`/`stval`）
  - 设置 HS trap vector（`stvec` → VM Exit 汇编入口）
  - **关键寄存器配置**：
    - `hstatus.SPV = 1`（SRET 后 V=1，进入虚拟模式）
    - `sstatus.SPP = 1`（nominal privilege = Supervisor，进入 VS 而非 VU）
    - HS `sepc = vcpu.run_pc`（VM entry 跳转目标来自 run PC，不是 `vsepc`）
  - 写 `hedeleg`：VU ecall 委托给 VS（guest syscall），VS ecall **不委托**（hypercall/VM Exit），guest-page-fault/virtual-instruction 不委托
  - 写 `hideleg`：bit 6(timer)/2(software) 委托给 VS；bit 10(external) 按需——注入虚拟外部中断时需 `hideleg[10]=1`
  - 写 `hgatp`：G-stage 页表基址 + VMID
  - 写 `hcounteren`：使能 Guest Timer/Cycle/Instret 计数器
  - SRET → VS-mode → Guest 执行
  - VM Exit 时：汇编入口保存全部 Guest GPR，读 `scause`/`sepc`/`stval`/`htval`/`htinst`/`hstatus`，恢复 Host 上下文；将 HS `sepc` 保存为 vCPU run PC，分发到 Rust 构造 `ExitReason`
  - 执行 `HFENCE.GVMA`（如果 G-stage 映射被修改过）

**依赖**：M1 完成（hypext 模块可用，含 HS trap vector + VS CSR 上下文 + shim crate 骨架）
**交付物**：6 个核心函数完整实现代码

#### M3: QEMU 原型验证

- Phase A: 编写原型验证入口
  - **前置条件检查**：
    - 确认 M-mode firmware 已将 cause 10 委托给 HS：`medeleg[10]=1`（否则 `ecall from VS-mode` 会先进入 M-mode，HS handler 拿不到 `scause=10`）
    - 后续还需验证 `medeleg` 的 virtual-instruction(22) 和 guest-page-fault(20/21/23) 位
  - 在 Asterinas 内核启动后调用 M2 的 6 个函数
  - Guest 代码：预编译的 RISC-V 指令序列 `nop; ecall`（4 字节对齐）
  - Guest 物理内存：分配 4KB 页，调用 `hyp_map_guest_memory` 构建 G-stage 映射（gpa=0x80000000, hpa=phys_page, perms=R|W|X），写入 Guest 指令后执行 `fence.i`（保证 I-cache 同步，架构上不保证 guest fetch 到刚写入的指令）
  - `hyp_vcpu_create` 确保 `vsatp=0`（VS-stage Bare，否则 `0x80000000` 还需经 guest 页表翻译）
- Phase B: QEMU 验证（精确标准，Codex 指定）
  - 启动 QEMU RISC-V + H-extension（`qemu-system-riscv64 -M virt -cpu rv64,h=true`）
  - 日志输出顺序：
    1. `hyp_vm_create()` → `VmHandle(vmid=1)`
    2. `hyp_pin_memory()` → phys page allocated
    3. `hyp_map_guest_memory(gpa=0x80000000, ...)` → G-stage PTE 建立
    4. `hyp_vcpu_create()` → vCPU created
    5. `hyp_vcpu_set_reg(Pc, 0x80000000)` → `vcpu.run_pc=0x80000000`（写入 vCPU 的 run PC 字段，不是硬件 `vsepc`）
    6. `hyp_vcpu_run()`: `hstatus.SPV=1` + `sstatus.SPP=1` → SRET → Guest 执行 `nop; ecall`
    7. VM Exit: `scause=10` (Environment call from VS-mode) **未被** `hedeleg` 委托
    8. HS trap handler 捕获 → 将 HS `sepc` 保存为 vCPU run PC → 返回 `ExitReason::EcallFromVs`
  - CSR dump 验证项：`hstatus.SPV=1`（VM exit 时硬件将 trap 前的 V 值写入 SPV；Guest 在 VS-mode 时 V=1，故 SPV=1）、`sstatus.SPP=1`（进入时 nominal privilege）、`hgatp`（含 VMID）、`scause=10`、**HS `sepc=0x80000004`**（ecall 的地址，即 nop 之后；此为 HS 级 sepc 而非 vsepc）、`htval`、`htinst`
- Phase C: 问题修复迭代
  - 常见预期问题：
    - `hgatp` MODE/PPN 编码错误 → 对照 Sv39x4 规范检查
    - G-stage page fault → 检查 PTE 位：`V=1`、`U=1`（G-stage 按类似 U-mode 检查权限）、`A=1`、`D=1`（对可写页）；若硬件不支持 A/D 自动更新，需软件置位或实现 A/D fault 补页逻辑
    - `hedeleg[10]=1` 导致 ecall 不退出 → 确认 VS ecall 对应位（bit 10）为 0；VU ecall 可以委托
    - `SRET` 进入 VU 而非 VS → 检查 `sstatus.SPP=1`（HS 级 sstatus，非 hstatus）
    - G-stage root page 未 16 KiB 对齐 → `hgatp` 规范要求
    - Guest 执行的第一条指令地址错误 → 检查 run PC 是否正确写入 HS `sepc`（非 `vsepc`）

**依赖**：M2 完成 + QEMU RISC-V 环境（`qemu-system-riscv64` ≥ 7.0）
**交付物**：原型验证报告（日志输出 + CSR dump + 结论）

#### M4: 其余 11 个函数签名 + 实现要点 + 综合评估

- Phase A: 完成 11 个函数的签名定义
  - 在 `asterinas-vmm-shim` 中放置函数签名，按 axvisor_api 模块分组
  - 每个函数体用 `todo!()` 占位，注释中写明实现要点
- Phase B: 编写从 6 函数到 17 函数的实现路径文档
  - 每个函数标注：对应的 axvisor_api trait 方法、依赖的 OSTD 子系统、预计行数、风险点
- Phase C: 综合评估
  - 6 函数→17 函数→axvisor 完整集成的三阶段路线图
  - 阻塞项和技术风险更新（含 Codex 指出的缺失项：guest SBI 策略、AIA/非-AIA fallback、vCPU kick/preempt、FPU/vector 状态策略、设备树传递、DMA/IOMMU 边界）
- Phase D: 后续工作建议
  - Phase 2：实现中断/定时器/MMIO 的完整路径
  - Phase 3：axvisor 侧 axvisor_api 切换到 shim，首台 VM 启动

**依赖**：M3 验证通过
**交付物**：完整接口清单（17 函数签名 + 注释，按 axvisor_api 模块分组） + 综合评估文档

### 里程碑依赖关系

```
M0 (axvisor_api 审计 + 前置条件) ──→ M1 (环境 + hypext + shim 骨架) ──→ M2 (6 核心函数实现) ──→ M3 (QEMU 原型验证) ──→ M4 (完整签名 + 评估)
```

### 最快关键路径（Critical Path）

```
  M0 (1-2 days): axvisor_api 审计 + 前置条件核对
                          │
  M1 (3-5 days): hypext (12 CSR + HFENCE.GVMA + VS CSR + HS trap vec) + shim 骨架
                          │
  M2 (5-7 days): vm_create / pin_memory / map_guest_memory / vcpu_create / set_reg / vcpu_run
                          │              ↑ 新增关键函数 (G-stage 页表 + hgatp + HFENCE.GVMA)
                          │
  M3 (2-3 days): nop; ecall → scause=10 → EcallFromVs + CSR dump 验证
                          │
  M4 (1-2 days): 剩余 11 函数签名 + 综合评估 (按 axvisor_api 模块分组)
```

---

## Implementation Notes

- 所有文档和注释使用中文，代码标识符使用英文（snake_case）
- RISC-V CSR 命名使用标准 RISC-V 特权规范命名（`hstatus`、`hedeleg` 等），不使用自创名称
- `asterinas-vmm-shim` 放在 Asterinas 源码树的 `services/vmm-shim/` 下
- 原型验证代码放在本仓库 `code/axvisor-asterinas-prototype/` 下
- **接口对齐**：shim 的 17 个函数应按 `axvisor_api` 的 trait 模块分组（`memory`/`vmm`/`arch`/`time`），shim 直接实现 axvisor_api trait，不额外定义独立的 `hyp_*` 自由函数抽象层（避免二次适配）
- `hyp_vcpu_run()` 中的 CSR 操作序列需加详细注释，标注每个 CSR 的作用和 RISC-V 规范章节号
- `hedeleg`/`hideleg` 的位字段必须在注释中标注每一位的异常/中断类型，禁止写全 1 的"全量委托"
- G-stage 页表 root page 必须 16 KiB 对齐（`hgatp` 规范要求），分配时需检查
- G-stage leaf PTE 写到 guest RAM 时，必须设置 `V=1 | U=1 | A=1 | D=1` + R/W/X 权限位（G-stage 按"类似 U-mode"检查权限）；`W=1` 时必须同时 `R=1`（禁止保留编码 R=0,W=1）；`G` bit 清零
- VMID 宽度是 WARL，需 probe 实际可用位数，不可假设 `u16` 全可用
- 每次写 `hgatp` 或修改 G-stage PTE 后必须执行 `HFENCE.GVMA`（RS1=0, RS2=0 全局刷新；RS1=guest_addr 指定 GPA 刷新），且必须在运行 vCPU 的 hart 上执行
- World switch（SRET 前后）必须用汇编/naked asm 实现：保存全部 Guest GPR 后才能进入 Rust handler；Rust 函数不能承担 SRET 前后的寄存器约定
- Guest SBI 策略需提前确定：VS guest 的 SBI call 通过 VS ecall 退出到 HS，需要最小实现（console 输出 + timer 设置 + shutdown），否则后续 Linux guest 无法走远
- MMIO 处理：未映射 MMIO 通过 guest-page-fault 退出，维护 memory slot/device region 表来分发，不能依赖 G-stage 页表逆查 GPA→HVA
- 不应在代码或文档中过度使用 emoji
- 每个 Phase 完成后可独立提交、独立评审
