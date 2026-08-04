# `axvisor_kvm_x86_bridge_runtime.c` 逐函数精讲

## 文件总览

### 角色

本文件是 **no_std x86 AxVisor KVM 桥（Rust bridge）的 C 运行时支撑层**。文件头注释（第 2-8 行）说明背景：这个 Rust bridge 被编译为 **AxVisor 风格的 no_std 对象**，而**不是** Linux 内核 Rust 对象。因此它无法直接用 Linux 内核 Rust 的 `alloc`/`kernel` crate，需要 C 侧提供一小组底层原语：内存分配器、日志、CPU/时间查询、页帧分配、地址转换、调度让核、以及 guest FPU 上下文切换。

本文件即这批原语的 C 实现，全部以 `axvisor_kvm_x86_bridge_*` 命名，供 Rust bridge 通过 FFI 调用。

### 在体系里的位置

- 上游：Rust x86 bridge（no_std）在需要堆分配、打日志、查 CPU 号、让核、进入 guest FPU 等时，FFI 调用本文件函数。
- 本层：用 Linux 内核 API（`kvmalloc`/`alloc_pages`/`ktime`/`schedule` 等）实现这些原语。
- 下游：Linux 内核内存/调度/FPU 子系统。

### 暴露/依赖的符号

- **依赖**：`axvisor_kvm_x86_bridge_runtime.h`（第 31 行 include，声明这些函数）；大量 Linux 头（align/cpu/delay/gfp/ktime/minmax/mm/printk/sched/smp/slab/string/vmalloc/asm-page，第 12-26 行；x86_64 下的 `asm/fpu/api.h`，第 27-29 行）。
- **内部**：`AXKVM_X86_BRIDGE_ALLOC_MAGIC`（第 33 行）、`struct axkvm_x86_bridge_alloc_header`（第 35-39 行）。
- **提供**：约 21 个 `axvisor_kvm_x86_bridge_*` 运行时函数（分配/释放/日志/CPU/时间/页帧/地址转换/让核/FPU）。

---

## 逐函数讲解

### 序言、Magic 与分配头（第 10-39 行）

- 第 10 行统一 `pr_fmt` 前缀 `axvisor_kvm_x86_bridge: `。
- 第 33 行 `AXKVM_X86_BRIDGE_ALLOC_MAGIC 0x41584b564d583836ULL`：一个 magic 值（其 ASCII 恰为 `AXKVMX86`），用于校验分配来源、检测非法/损坏指针。
- 第 35-39 行 `struct axkvm_x86_bridge_alloc_header`：每次分配的**隐藏头部**，含 `magic`（校验）、`raw`（`kvmalloc` 返回的原始指针，用于释放）、`size`（用户请求的大小，realloc 时决定拷贝量）。这是一个"带头部的对齐分配器"的经典布局。

### `axkvm_x86_bridge_header_from_ptr`（第 41-54 行）——头部反查与校验

从用户指针反推出头部并校验：

- 第 46-47 行 NULL 指针直接返回 NULL。
- 第 49 行 `(struct ... *)ptr - 1`：头部就紧贴在用户指针**前一个 header 大小**处（分配时如此布局）。
- 第 50-51 行校验 `magic`，不匹配返回 NULL——这是防止 Rust 传入非本分配器产生的指针、或内存越界踩坏头部的安全闸。
- 第 53 行返回头部。

### `axvisor_kvm_x86_bridge_alloc`（第 56-84 行）——对齐分配器

为 Rust 提供 `alloc(size, align)` 语义（Rust 的 `GlobalAlloc` 需要显式对齐）：

- 第 64-65 行 size 为 0 返回 `ZERO_SIZE_PTR`（对齐 Rust/内核对零长分配的约定，返回一个非 NULL 但不可解引用的哨兵）。
- 第 67 行 `align = max(align, __alignof__(*header))`：对齐至少要能容纳头部本身的对齐要求。
- 第 68-70 行 `check_add_overflow` 两次：计算 `total = size + align + sizeof(header)`，任一步溢出返回 NULL——防止整数溢出导致的堆越界。
- 第 72-74 行 `kvmalloc(total, GFP_KERNEL)`（`kvmalloc` 会在物理连续分配失败时回退到 vmalloc，适合较大分配）；失败返回 NULL。
- 第 76-78 行**对齐计算**：从 `raw + sizeof(header)` 起，`ALIGN` 到 `align` 边界得到 `aligned_addr`（返回给用户的指针），头部落在其前一格。这保证用户指针满足对齐、且前面留得下头部。
- 第 79-81 行填头部：写 magic、保存 `raw`（供释放）、记 `size`。
- 第 83 行返回对齐后的用户指针。

### `axvisor_kvm_x86_bridge_dealloc`（第 86-101 行）——释放 + 越界检测

- 第 90-91 行 NULL 或 `ZERO_SIZE_PTR` 直接返回（与 alloc 的零长约定对称）。
- 第 93-97 行反查头部；若校验失败（magic 不符），**打印 `pr_err` 并拒绝释放**——把潜在的双重释放/野指针变成可诊断的日志而非内核崩溃。
- 第 99 行把 `magic` 清 0（毒化头部，令后续对同指针的再次 dealloc/反查失败，防双重释放）。
- 第 100 行 `kvfree(header->raw)` 释放原始块（与 `kvmalloc` 配对）。

### `axvisor_kvm_x86_bridge_realloc`（第 103-126 行）——重分配

实现 Rust 分配器的 realloc 语义：

- 第 108-109 行原指针为空/零长哨兵时，等价于全新分配 `alloc(new_size, align)`。
- 第 110-113 行 `new_size == 0` 时等价于释放，返回 `ZERO_SIZE_PTR`。
- 第 115-117 行反查旧头部，校验失败返回 NULL。
- 第 119-121 行分配新块，失败返回 NULL（旧块保持不动，符合 realloc 失败语义）。
- 第 123 行 `memcpy` 拷贝 `min(old_size, new_size)` 字节——用旧头部记录的 `size` 精确控制拷贝量（缩小时不越读，扩大时不越写）。
- 第 124-125 行释放旧块并返回新指针。

### `axvisor_kvm_x86_bridge_log`（第 128-136 行）——日志出口

- 第 130 行 `clipped = min(len, 256)`：**限长 256 字节**，防止 Rust 传入超长/无终止符的缓冲区刷爆日志。
- 第 132-133 行 NULL 直接返回。
- 第 135 行 `pr_err("%.*s\n", (int)clipped, bytes)`：用精度限定符按字节数打印（不依赖 C 字符串的 NUL 终止），把 Rust 的字节切片安全地送到内核日志。

### CPU / 任务 / 时间查询原语（第 138-166 行）

一组极薄的内核 API 包装，供 Rust 查询运行环境：

- `get_cpu_num`（第 138-141 行）：`num_online_cpus()`，在线 CPU 数。
- `current_cpu_id`（第 143-146 行）：`smp_processor_id()`，当前物理 CPU 号。
- `current_task_id`（第 148-151 行）：把 `current`（task_struct 指针）当作不透明 ID 返回（`(size_t)current`）——Rust 侧只用作身份标识，不解引用。
- `migrate_disable` / `migrate_enable`（第 153-161 行）：暴露迁移禁用/恢复，供 Rust 在进 guest 前后钉核。
- `current_time_nanos`（第 163-166 行）：`ktime_get_ns()`，单调纳秒时钟，供 Rust 侧计时。

### `axvisor_kvm_x86_bridge_alloc_frame`（第 168-177 行）——物理页帧分配

为 Rust 提供"要一整个物理页帧"的原语（EPT/页表用）：

- 第 172 行 `alloc_pages(GFP_KERNEL | __GFP_ZERO, 0)`：分配 1 页（order 0）且清零。
- 第 173-174 行失败返回 0（Rust 侧以 0 判失败）。
- 第 176 行返回 `page_to_phys(page)`——**返回物理地址**而非虚拟地址，符合页表项需要物理帧号的用途。

### `axvisor_kvm_x86_bridge_dealloc_frame`（第 179-188 行）——页帧释放

- 第 183-184 行防御：`paddr` 为 0 或 `pfn_valid` 失败（无效 PFN）直接返回——避免对非法物理地址操作。
- 第 186-187 行 `phys_to_page` 反查 struct page 后 `__free_pages(page, 0)` 释放。

### `axvisor_kvm_x86_bridge_phys_to_virt`（第 190-206 行）——物理→虚拟

把物理地址翻译成内核可解引用的虚拟地址：

- 第 196-197 行 0 或无效 PFN 返回 0。
- 第 199-200 行 `phys_to_page` → `page_address` 取页首虚拟地址；`page_address` 为空（如 highmem 未映射）返回 0。
- 第 204-205 行 `offset = paddr & (PAGE_SIZE-1)` 保留页内偏移，加回虚拟页首得到完整虚拟地址。这处理了"物理地址不页对齐"的一般情形。

### `axvisor_kvm_x86_bridge_virt_to_phys`（第 208-220 行）——虚拟→物理

- 第 212-213 行 0 返回 0。
- 第 216-217 行 `virt_addr_valid` 校验地址是否为可做 `__pa` 的线性映射地址（拒绝 vmalloc/ioremap 等非线性地址）。
- 第 219 行 `__pa(ptr)` 转物理。这与 `phys_to_virt` 构成一对（仅适用于线性映射区）。

### 调度让核原语（第 222-288 行）——超订核心，KVM 语义对齐

这四个函数是 MEMORY 中反复出现的"超订让核"问题的落点。每个都带长注释解释与 KVM 行为的对齐关系，是本文件最需逐行理解处。

#### `axvisor_kvm_x86_bridge_yield_now`（第 222-225 行）

第 224 行 `yield()`。最弱的让核——注释在后续函数中指出：CFS 后端 `yield_task_fair()` 在 runqueue 只有当前任务时是 **no-op**，即"每核一线程"的超订布局下等于什么都不做。作为基线原语保留。

#### `axvisor_kvm_x86_bridge_park_now`（第 227-240 行）

- 注释（第 227-236 行）解释：与 `yield()` 不同，`schedule_timeout_interruptible(1)` 会把当前任务**移出 runqueue 一个 tick**，真正释放物理核让 CFS 调度另一个 runnable 的 vCPU 线程。类比 KVM 的 `kvm_vcpu_block()/schedule()` 为 halt/长自旋的 vCPU 让出 pCPU。选 interruptible 是为了让 pending signal（KVM_RUN abort）能及时打断。
- 第 239 行 `schedule_timeout_interruptible(1)`。

#### `axvisor_kvm_x86_bridge_schedule_now`（第 242-268 行）

- 长注释（第 242-264 行）对比三者：`park_now` 会 TASK_INTERRUPTIBLE 移出 runnable 集整整一个 jiffy（观测到会让 parked AP 在超订下再也拿不到有用工作）；`cond_resched` 受 `TIF_NEED_RESCHED` 门控、在单任务 runqueue 上是 no-op；而 `schedule()` **无条件进入 `__schedule()`（SM_NONE）且任务仍保持 runnable**，被立即重新入队、马上再度可运行。
- 注释进一步说明这是"两次进 guest 之间的 reschedule 点"的 **KVM-faithful 原语**：KVM 的 vcpu_run 外层循环在 preemption-enabled 下、每次 VM-exit 后遇 `_TIF_NEED_RESCHED` 就真的 `schedule()`；`kvm_vcpu_on_spin()` 本身从不 block/sleep，只是尝试几次 `yield_to` 就返回。这里镜像该行为：保持线程 runnable，让 CFS 把必须运行的兄弟线程（驱动 `cpuhp_bp_sync_alive` 的 BSP）协同调度到空出的核，而不是 block-park 掉 AP。
- 第 267 行 `schedule()`。

#### `axvisor_kvm_x86_bridge_cond_resched`（第 270-288 行）

- 长注释（第 270-284 行）：`cond_resched()` 仅在 `TIF_NEED_RESCHED` 置位（host 调度 tick / 负载均衡想在此核跑别的任务）时让核，且一被重新选中就返回——vCPU 线程全程保持 RUNNABLE。这被描述为"KVM-faithful 超订原语"：KVM 让所有 vCPU 线程保持 runnable，靠 CFS 时间片（host tick 触发 need_resched）把 N 个 vCPU 线程摊到 M<N 个核上，而不是把自旋 vCPU 移出 runqueue（那会把它踢出 CFS 均衡集）。与 `yield()`（单任务 runqueue 上 no-op）和 `park_now()`（schedule_timeout block）都不同，`cond_resched` 只在调度器真的请求时才让核然后立即恢复。
- 第 287 行 `return cond_resched()`（返回 1 表示确实发生了 reschedule）。

四者构成一个"让核强度梯度"：`yield_now`（最弱/常 no-op）→ `cond_resched`（按需、保持 runnable）→ `schedule_now`（无条件、保持 runnable）→ `park_now`（最强、移出 runqueue 一个 tick）。Rust bridge 据不同场景选用。

### `axvisor_kvm_x86_bridge_guest_fpu_begin`（第 290-299 行）——进入 guest FPU 上下文

进入 guest 前借用内核 FPU 上下文（保护/切换 FPU 状态）：

- 第 292 行 `#ifdef CONFIG_X86_64` 全体包裹（非 x86_64 直接返回 0）。
- 第 293-294 行 `irq_fpu_usable()` 检查当前上下文能否用 FPU（如在硬中断里则不能），不可用返回 `-EBUSY`，让 Rust 侧知难而退。
- 第 296 行 `kernel_fpu_begin_mask(KFPU_387 | KFPU_MXCSR)`：以只保护 x87(387) 与 MXCSR 的掩码进入内核 FPU 区（比全量保护更轻，够 guest 切换所需）。
- 第 298 行返回 0（成功）。

### `axvisor_kvm_x86_bridge_guest_fpu_end`（第 301-306 行）——退出 guest FPU 上下文

第 303-305 行 `#ifdef CONFIG_X86_64` 内调用 `kernel_fpu_end()`，与 `guest_fpu_begin` 的 `kernel_fpu_begin_mask` 配对，恢复被抢占保存的 FPU 状态。非 x86_64 为空操作。

---

## 小结

本文件约 306 行，是 no_std Rust x86 bridge 的 C 运行时垫片。核心内容：(1) 一个**带 magic 校验头 + 显式对齐**的分配器三件套（alloc/dealloc/realloc），以 `kvmalloc` 为底、以 magic 防野指针；(2) 一批薄封装的 CPU/时间/页帧/地址转换原语；(3) 最具分量的**四级让核原语梯度**（yield/cond_resched/schedule/park），其长注释精确对齐了 KVM 在超订场景下"保持 vCPU 线程 runnable、靠 CFS+need_resched 摊核"的调度语义；(4) x86_64 下的 guest FPU 上下文 begin/end 配对。
