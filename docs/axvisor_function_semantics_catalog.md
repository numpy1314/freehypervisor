# Axvisor 函数语义目录（附源码）

> 目标：在开始做 Asterinas 侧实现之前，把 **完整 axvisor 启动链路里已经实际依赖到的函数** 的职责、语义边界、源码位置先钉死。
>
> 范围：
> - 只写当前“跑完整 axvisor”已经进入的真实调用路径。
> - 每项都给出 upstream Axvisor/ArceOS 源码，以及 Asterinas 当前对应源码。
> - 每项都明确结论：`语义等价` / `部分等价` / `不等价` / `缺失`。

---

## 1. 先给结论：当前已经确认并已修正的关键点

完整 axvisor 在 Asterinas 上已经走到：

1. `config::init_guest_vm()`
2. `handle_fdt_operations()`
3. `VM::new(vm_config)`
4. `vm_alloc_memorys()`
5. `axvm::AxVM::alloc_memory_region()`

最先确认的真实阻塞点不是“5 个 trait 不够”，而是下面这组 guest RAM backing 语义不等价：

- upstream 把 `alloc_zeroed(layout)` 得到的 **heap HVA**
  直接喂给 `virt_to_phys()`
- 然后把拿到的 HPA 作为一整段连续物理内存去做 `map_linear(gpa, hpa, len)`
- 这隐含要求：
  - `virt_to_phys()` 能处理这类 HVA
  - 该 HVA 背后的 backing 对应一整段可线性映射的连续 HPA

而 Asterinas 当前 `virt_to_phys()` 只接受 **linear mapping 区间内的 VA**，不接受一般 heap/vmalloc VA。

### 1.1 原始 upstream 源码

文件：[vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:901)

```rust
pub fn alloc_memory_region(&self, layout: Layout, gpa: Option<GuestPhysAddr>) -> AxResult<&[u8]> {
    let hva = unsafe { alloc::alloc::alloc_zeroed(layout) };
    let s = unsafe { core::slice::from_raw_parts_mut(hva, layout.size()) };
    let hva = HostVirtAddr::from_mut_ptr_of(hva);

    let hpa = axvisor_api::memory::virt_to_phys(hva);
    let gpa = gpa.unwrap_or_else(|| hpa.as_usize().into());

    let mut g = self.inner_mut.lock();
    g.address_space.map_linear(gpa, hpa, layout.size(), ...)?;
}
```

### 1.2 Asterinas 原始对应源码

文件：[hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:16)

```rust
/// Convert a virtual address (within the linear mapping range) back to
/// the corresponding physical address.
///
/// # Panics
///
/// Panics if `vaddr` is not within the linear mapping range.
pub fn virt_to_phys(vaddr: Vaddr) -> Paddr {
    crate::mm::kspace::vaddr_to_paddr(vaddr)
}
```

### 1.3 已落地的修正

- `alloc_memory_region()` 的真实语义不是“拿一块随便的宿主内存”，而是“拿一段真实连续物理 backing，并且 host 侧仍可通过 linear mapping 访问它”。
- 现在已经按这个语义修正：
  - Asterinas OSTD 新增：
    - [allocator.rs](/home/bullet1517/asterinas/ostd/src/mm/frame/allocator.rs:67) `alloc_aligned_segment()`
    - [allocator.rs](/home/bullet1517/asterinas/ostd/src/mm/frame/allocator.rs:104) `alloc_aligned_segment_with()`
    - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:39) `alloc_segment()`
  - Asterinas adapter 改为真实连续物理段分配：
    - [memory.rs](/home/bullet1517/asterinas/kernel/comps/axvisor-adapter/src/memory.rs:33)
  - AxVM guest RAM 分配改为走 `axvisor_api::memory::alloc_contiguous_frames()` 再 `phys_to_virt()`：
    - [vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:905)
- 结论：
  - “heap HVA 直接 `virt_to_phys()`” 这条错误路径已经移除。
  - 当前 guest RAM backing 语义已从 `不等价` 修正到 `基本等价`。

---

## 2. Host Substrate

## 2.1 `virt_to_phys`

- upstream 使用点：
  - [vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:918)
  - [page.rs](/home/bullet1517/tgoskits/os/arceos/modules/axalloc/src/page.rs:51)
  - [paging.rs](/home/bullet1517/tgoskits/os/arceos/modules/axhal/src/paging.rs:20)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:48)
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:16)
- 语义：
  - 输入一个宿主 VA，返回其 backing 的宿主 PA。
  - 对 axvisor 而言，这不是“调试辅助函数”，而是 guest memory 建图前的关键基础操作。
  - 当上层把它用于整段 guest RAM backing 时，它必须和 backing 分配语义一起看。
- 结论：`部分等价`
  - Asterinas 当前仍只支持 linear-mapped VA。
  - 但因为 guest RAM 分配路径已改成“先拿连续 HPA，再转回 linear-mapped HVA”，当前完整 axvisor 启动路径不再依赖“普通 heap HVA -> HPA”。

## 2.2 `phys_to_virt`

- upstream 使用点：
  - [paging.rs](/home/bullet1517/tgoskits/os/arceos/modules/axhal/src/paging.rs:31)
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:53)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:53)
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:10)
- 语义：
  - 把宿主 PA 转回内核可访问 VA。
  - 这里默认目标 PA 已经落在内核线性映射覆盖范围。
- 结论：`语义等价`

## 2.3 `alloc_frame` / `alloc_frames`

- upstream：
  - [paging.rs](/home/bullet1517/tgoskits/os/arceos/modules/axhal/src/paging.rs:15)
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:45)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:112)
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:26)
- 语义：
  - 为页表或 hypervisor 元数据分配页框。
  - 调用方关心的是“拿到能用于页表的物理页”，不是 heap 字节分配。
- 结论：`基本等价`
  - 单页 `alloc_frame` 没问题。
  - 多页 `alloc_frames(num)` 在 Asterinas 里通过 `alloc_segment(num)` 保留物理连续 segment。
  - 另外 guest RAM backing 现在也已经通过 adapter 的 `alloc_contiguous_frames()` 打通，不再只停留在分页 handler。

## 2.4 `GlobalPage::alloc_contiguous`

- upstream：
  - [page.rs](/home/bullet1517/tgoskits/os/arceos/modules/axalloc/src/page.rs:34)
- Asterinas 当前对应实现：
  - [ax_alloc.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_alloc.rs:34)
  - [memory.rs](/home/bullet1517/asterinas/kernel/comps/axvisor-adapter/src/memory.rs:33)
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:39)
- 语义：
  - 分配连续 4K 页，调用方可以显式把它当成一整段连续物理内存。
  - 这才是更接近 guest RAM backing 的分配接口。
- 结论：`基本等价`
  - `asterina-std::modules::ax_alloc::global_allocator().alloc_pages()` 已能返回真实连续物理页段对应的 linear-mapped VA。
  - `axvisor_adapter::alloc_contiguous_frames()` 也已提供 HPA 视角的对等封装，满足当前 axvm/axvisor 用法。

## 2.5 `PagingHandlerImpl::{alloc_frames,dealloc_frames,phys_to_virt}`

- upstream：
  - [paging.rs](/home/bullet1517/tgoskits/os/arceos/modules/axhal/src/paging.rs:15)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:102)
- 语义：
  - 这是 `ax-page-table-multiarch` 的底层 allocator adapter。
  - 只负责“页表页”的生命周期，不负责 guest RAM 的 backing。
- 结论：`基本等价`
  - 但要明确它不能拿来证明 `alloc_memory_region` 的语义已经等价。

## 2.6 `current_ticks` / `ticks_per_sec` / `ticks_to_nanos` / `nanos_to_ticks`

- upstream 依赖：
  - `axvisor_api::time::*`，最终被 axvisor timer/vcpu timeout 路径使用
  - [vcpus.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/vcpus.rs:26)
- Asterinas 当前实现：
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:44)
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:61)
- 语义：
  - `current_ticks` 必须是单调前进的 host 计时源。
  - `ticks_per_sec` 给出该计时源频率。
  - 两个换算函数必须和同一个计时基准一致。
- 结论：`语义等价`
  - 尤其在 RISC-V 下直接读 `time` CSR，这比依赖 timer interrupt 更稳。

## 2.7 `busy_wait`

- upstream 使用点：
  - [vcpus.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/vcpus.rs:26)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:88)
- 语义：
  - 忙等一段时间，不依赖调度器唤醒。
  - 主要用于启动/轮询阶段的小延时。
- 结论：`语义等价`

---

## 3. Runtime Substrate

## 3.1 `KernelGuardIf::{disable_preempt, enable_preempt}`

- upstream：
  - [api.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/api.rs:53)
- Asterinas 当前状态：
  - `asterina-std` 的 `ax_task` shim 里没有同名实现
  - 当前 axvisor 启动链路没有直接走到这层 `ax_crate_interface` 绑定
- 语义：
  - 为 `SpinNoIrq` / guard 体系提供“关抢占、开抢占”的底层钩子。
  - 它不是普通任务 API，而是锁和调度器一致性的一部分。
- 结论：`缺失，但当前启动路径未直接依赖`
  - 它仍然是“要做到 ArceOS runtime substrate 逐层等价”时需要补的接口。
  - 但对当前 Asterinas 这套 `WaitQueue`/task shim 启动链路，已不是第一顺位阻塞项。

## 3.2 `WaitQueue::{wait,wait_until,notify_one,notify_all}`

- upstream：
  - [wait_queue.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/wait_queue.rs:43)
- Asterinas 当前实现：
  - [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:281)
- 语义：
  - `wait`：阻塞当前 task，直到被唤醒。
  - `wait_until`：条件不满足时持续阻塞；即便被误唤醒也要重新检查条件。
  - `notify_one/notify_all`：唤醒等待者。
- 关键差异：
  - upstream `WaitQueue` 持有 `SpinNoIrq<VecDeque<AxTaskRef>>`，并和 run queue/抢占/IRQ 状态一起协作。
  - Asterinas shim 直接包装 `ostd::sync::WaitQueue`。
- 结论：`部分等价`
  - 对 axvisor 当前用法基本够用。
  - 但它不是 ArceOS 那套 “wait-queue + run-queue + irq/preempt guard” 的逐位等价实现。

## 3.3 `spawn_task`

- upstream：
  - [api.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/api.rs:177)
- Asterinas 当前实现：
  - [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:328)
- 语义：
  - 输入 `TaskInner`，创建一个可运行的内核任务。
  - 必须保留 task name、task-ext、cpumask 等 axvisor 会用到的附加信息。
- 结论：`部分等价`
  - Asterinas shim 已保留 `TaskExt`、`cpumask` 和 `current().task_ext()` 访问路径。
  - 但底层调度/迁核/阻塞模型并不是 ArceOS 原生实现。

## 3.4 `current`

- upstream：
  - [api.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/api.rs:124)
- Asterinas 当前实现：
  - [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:413)
- 语义：
  - 返回当前 task 的抽象视图。
  - 对 axvisor 关键点在于：`ax_task::current().as_vcpu_task()` 这条链必须成立。
- 结论：`语义等价`
  - 当前 shim 专门为了 `AsVCpuTask` 这条链做了包装。

## 3.5 `yield_now`

- upstream：
  - [api.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/api.rs:271)
- Asterinas 当前实现：
  - [freehypervisor lib.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/lib.rs:46)
  - [ostd task mod.rs](/home/bullet1517/asterinas/ostd/src/task/mod.rs:92)
- 语义：
  - 当前任务主动让出 CPU。
  - 调用方不要求睡眠语义，只要求给别的 runnable task 一个运行机会。
- 结论：`语义等价`

## 3.6 `set_current_affinity`

- upstream：
  - [api.rs](/home/bullet1517/tgoskits/os/arceos/modules/axtask/src/api.rs:234)
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:97)
- Asterinas 当前实现：
  - [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:419)
- 语义：
  - 约束当前任务只能在给定 CPU mask 上运行。
  - Axvisor 用它把“每核虚拟化 enable 流程”绑定到目标物理核。
- 结论：`基本等价`
  - `asterina-std` shim 允许安装 runtime hook：
    - [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:66)
  - Asterinas hypervisor 模式启动时已安装真实 affinity/migration hook：
    - [init.rs](/home/bullet1517/asterinas/kernel/src/init.rs:221)
  - 当前实现会更新真实 `Thread` affinity，并在必要时触发 `ostd::task::scheduler::migrate_current()`。

## 3.7 `percpu::this_cpu_id`

- upstream：
  - [axhal percpu.rs](/home/bullet1517/tgoskits/os/arceos/modules/axhal/src/percpu.rs:3)
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:17)
- Asterinas 当前实现：
  - [ax_hal.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_hal.rs:149)
- 语义：
  - 返回当前物理 CPU 逻辑编号。
  - 这是 per-CPU vcpu state、定时器、虚拟化 enable 流程的索引基准。
- 结论：`语义等价`

---

## 4. Native Hypervisor Substrate

## 4.1 `hardware_check`

- upstream：
  - [riscv64 mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/arch/riscv64/mod.rs:9)
- Asterinas 当前实现：
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:101)
- 语义：
  - 检查硬件虚拟化能力是否可用。
  - 在 RISC-V 下至少要确认 H extension 可见、相关 CSR 可访问。
- 结论：`Asterinas 更强`
  - upstream 这里几乎是空壳
  - Asterinas 已做 H extension 检查与 CSR 可访问性验证

## 4.2 `enable_virtualization`

- upstream 调用入口：
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:77)
- Asterinas 当前底层实现：
  - [hypervisor.rs](/home/bullet1517/asterinas/ostd/src/hypervisor.rs:119)
- 语义：
  - 每个物理核都必须完成 hypervisor CSR 初始化。
  - 包括 `hedeleg`、`hideleg`、`hcounteren`、`hvip`、`hstatus`、`sie` 等。
  - 必须发生在该核上任何 vCPU 进入之前。
- 结论：`语义等价`
  - 并且 Asterinas 注释里已经明确要求“bit-exact mirror of axvisor percpu setup”

## 4.3 `AxVMPerCpu::init()` / `hardware_enable()`

- upstream 调用点：
  - [hal/mod.rs](/home/bullet1517/tgoskits/os/axvisor/src/hal/mod.rs:108)
- Asterinas 当前状态：
  - 调用链已经存在，底层依赖前述 `enable_virtualization()` 和 per-CPU 环境
- 语义：
  - 建立该物理核上的 hypervisor per-CPU 状态，并真正 enable 本核虚拟化执行环境。
- 结论：`已接通，但需要继续核验`
  - 当前不再是已知主阻塞点。
  - 后续应继续核对它和 task affinity / per-CPU 初始化顺序是否完全一致。

## 4.4 `config::init_guest_vm`

- upstream：
  - [config.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/config.rs:184)
- 语义：
  - 从配置构造 `AxVMCrateConfig` / `AxVMConfig`
  - 处理 DTB/FDT
  - 创建 VM
  - 分配 guest memory
  - 装载 kernel/initramfs/dtb
  - 调 `vm.init()`
- 结论：`已确认 Asterinas 可走到 vm_alloc_memorys`
  - 所以它之前那一层的 runtime/hyp 初始化，不再是当前一号嫌疑。

## 4.5 `vm_alloc_memorys`

- upstream：
  - [config.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/config.rs:276)
- 语义：
  - 按 VM config 为每个 memory region 分配 backing 并加入 VM address space。
  - 它是 guest RAM backing 语义开始真正落地的入口。
- 结论：`当前已进入，并在下游 alloc_memory_region 处暴露不等价`

## 4.6 `AxVM::new`

- upstream：
  - [vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:178)
- 语义：
  - 创建空 VM 对象
  - 创建空 guest `AddrSpace`
  - 此时还未分配 guest RAM，也未创建完整 vCPU 列表
- 结论：`已通过`

## 4.7 `AxVM::alloc_memory_region`

- upstream：
  - [vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:901)
- 语义：
  - 为一个 guest region 分配 backing
  - 求得 backing HPA
  - 用 `map_linear(gpa, hpa, len)` 把整个 region 建到 guest 地址空间
- 隐含前提：
  - backing 对应连续 HPA
  - `virt_to_phys(hva)` 可用于该类 hva
- 结论：`当前主阻塞点`

## 4.8 `AxVM::map_reserved_memory_region`

- upstream：
  - [vm.rs](/home/bullet1517/tgoskits/components/axvm/src/vm.rs:944)
- 语义：
  - 不重新分配 backing，而是把“已知物理保留区”直接映射给 guest。
  - 默认 `gpa == hpa`，是 identity/预留区映射路径。
- 结论：`语义清楚，但不是当前卡点`

## 4.9 `vcpus::setup_vm_primary_vcpu`

- upstream：
  - [vcpus.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/vcpus.rs:355)
- 语义：
  - 为 VM 建立 primary vCPU 对应的宿主 task
  - 绑定 `VCpuTask` 扩展
  - 放入等待队列，等待 boot 后被唤醒运行
- 结论：`依赖 task shim 语义成立`

## 4.10 `VMVCpus::{wait,wait_until,notify_one,notify_all}`

- upstream：
  - [vcpus.rs](/home/bullet1517/tgoskits/os/axvisor/src/vmm/vcpus.rs:143)
- Asterinas 当前承接：
  - 底层最终落到 [ax_task.rs](/home/bullet1517/asterinas/kernel/comps/asterina-std/src/os/arceos/modules/ax_task.rs:281) 的 `WaitQueue`
- 语义：
  - 控制每个 VM 的 vCPU task 何时阻塞、何时被启动、何时在 shutdown 时统一唤醒。
- 结论：`当前够用，但仍是 shim 级等价，不是 ArceOS 原生等价`

---

## 5. 需要在 Asterinas 侧补齐的接口清单

按优先级排序：

1. `guest memory backing` 语义封装
   - 目标不是再包装一次 `heap + virt_to_phys`
   - 目标是提供“可求 HPA、可线性映射、物理连续或可逐页建图”的 guest RAM backing 抽象
2. `GlobalPage::alloc_contiguous` 对等接口
   - 或者功能等价的 `HostGuestRamRegion`
3. `KernelGuardIf`
   - 让 `SpinNoIrq` / guard 体系与 Asterinas 调度模型彻底对齐
4. `真实 affinity hook`
   - 确保 `set_current_affinity()` 不是只改元数据
5. `WaitQueue` 语义复核
   - 明确是否需要补 ArceOS 风格的 wait-queue/run-queue 协作语义

---

## 6. 实现前的硬约束

后续在 Asterinas 侧写实现时，必须遵守这三条：

- 不能把 `virt_to_phys()` 的地址域偷偷放宽到“任何 heap 指针都行”，除非 backing 模型本身真的支持。
- 不能把“虚拟地址连续”等同于“物理地址连续”。
- 不能因为 MS5 probe 已经过 world switch，就假设完整 axvisor 的 runtime 依赖已经全部等价。

这份文档之后，下一步才应该进入 Asterinas 侧逐项封装实现。
