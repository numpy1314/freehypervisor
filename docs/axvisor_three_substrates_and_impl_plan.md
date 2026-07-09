# Axvisor 三层依赖与下一步封装实现

> 目标：把“Axvisor 真实依赖了 ArceOS 哪些东西”从概念判断，落成一份可直接指导封装实现的任务拆解。

---

## 一、重新归纳后的结论

如果按真实运行内容而不是抽象 trait 名字来列，Axvisor 依赖的是：

- `axalloc`
- `axhal`
- `axtask`
- `axruntime`
- `ax-kspin` guard 体系
- ArceOS hypervisor mode 初始化逻辑
- SBI firmware
- 基础平台 I/O

这些依赖不属于同一层，应该拆成三个 substrate：

1. `host substrate`
2. `runtime substrate`
3. `native hypervisor substrate`

这三个层次都必须被 Asterinas 侧显式封装，不能再只围着 `axvisor_api` 五类 trait 打转。

---

## 二、三层 substrate 的边界

### 2.1 Host Substrate

这一层回答的问题是：

> “Axvisor 运行所需的宿主底层能力，Asterinas 从哪里给？”

对应 ArceOS 组件：

- `axalloc`
- `axhal` 中的：
  - CPU/平台初始化
  - timer
  - IRQ
  - CSR/MSR/架构寄存器原语
  - trap 原语
  - 地址空间/页表原语
  - 硬件虚拟化控制寄存器原语
- UART / console
- SBI 对接

建议封装面：

- `host_mem`
- `host_time`
- `host_irq`
- `host_arch`
- `host_console`

### 2.2 Runtime Substrate

这一层回答的问题是：

> “Axvisor 自己这套 runtime 如何在 Asterinas 上存活？”

对应 ArceOS 组件：

- `axtask`
- `axruntime`
- `.percpu`
- `KernelGuardIf`
- `SpinNoIrq`
- 早期初始化顺序

建议封装面：

- `rt_task`
- `rt_guard`
- `rt_percpu`
- `rt_bootstrap`
- `rt_waitqueue`

### 2.3 Native Hypervisor Substrate

这一层回答的问题是：

> “谁真正负责 VM/vCPU、world switch、G-stage 和 VM exit？”

对应内容：

- world switch
- HS trap
- G-stage
- guest CSR 状态
- 虚拟中断
- 虚拟 timer
- VM/vCPU 生命周期

建议封装面：

- `hv_vm`
- `hv_vcpu`
- `hv_mem`
- `hv_trap`
- `hv_irq`
- `hv_time`

---

## 三、下一步封装实现，不再按“trait 数量”推进

推荐直接按三层并行收口，但实现顺序必须串行：

### Phase A: 先收口 Host Substrate

目标：

- 把 Asterinas 当前已有的 OSTD/内核能力，整理成稳定的 host-facing facade
- 明确哪些能力只对 linear mapping 生效，哪些能力要求物理连续

必须先收口的接口：

- 连续物理内存分配
- HPA/HVA 转换
- timer / clock source
- local irq / irq-save
- CSR / H-extension 原语
- UART / console

这一阶段的核心产物不是“能跑 guest”，而是：

> 把 Asterinas 当前底座语义说清楚，尤其是 memory 语义。

### Phase B: 再收口 Runtime Substrate

目标：

- 让 Axvisor runtime 脱离 ArceOS 自己的 task/guard/bootstrap 假设

必须先收口的接口：

- spawn / yield / park / wake
- CPU affinity
- WaitQueue
- `.percpu`
- `KernelGuardIf`
- `SpinNoIrq` 语义
- early boot initialization order

这里的关键不是“先把所有 shell 功能补齐”，而是：

> 先把 runtime 生存所需的最小调度和 guard 语义闭合。

### Phase C: 最后收口 Native Hypervisor Substrate

目标：

- 把 guest 执行面从 Asterinas 现有底层能力中真正立起来

必须先收口的接口：

- VM/vCPU create/destroy
- guest RAM backing
- G-stage map/unmap
- VM entry / VM exit
- guest CSR/GPR/FPR save-restore
- virtual interrupt injection
- virtual timer state

---

## 四、当前最优先的实现主线

如果目标是“尽快跑通完整 Axvisor”，当前优先级必须是：

1. `host substrate` 里的 guest memory backing 语义
2. `runtime substrate` 里的最小 task/guard/percpu 语义
3. `native hypervisor substrate` 里的 VM/vCPU/G-stage/world switch

原因很简单：

- 现在 full runtime 已经证实能走到 `vm_alloc_memorys()`
- 当前第一阻塞点是 guest RAM backing 语义不等价
- 这说明第 1 层还没完全闭合

所以不能跳过去直接做：

- 更复杂的 `vmexit_handler`
- guest timer
- shell 功能
- 多 vCPU 调度

---

## 五、建议的 crate/模块组织

如果要在 Asterinas 侧真正实现，建议中间层不要做成一个平铺的大文件，而是至少拆成：

```text
asterinas-vmm-shim
  ├─ host/
  │   ├─ mem.rs
  │   ├─ time.rs
  │   ├─ irq.rs
  │   ├─ arch.rs
  │   └─ console.rs
  ├─ runtime/
  │   ├─ task.rs
  │   ├─ guard.rs
  │   ├─ percpu.rs
  │   ├─ waitq.rs
  │   └─ bootstrap.rs
  ├─ hv/
  │   ├─ vm.rs
  │   ├─ vcpu.rs
  │   ├─ mem.rs
  │   ├─ trap.rs
  │   ├─ irq.rs
  │   └─ time.rs
  └─ facade/
      ├─ axvisor_api_impl.rs
      └─ runtime_contract.rs
```

这样做的目的不是形式好看，而是避免再次把：

- OS substrate
- runtime glue
- hypervisor execution plane

重新混成一个 adapter。

---

## 六、落地判断标准

下一步封装是否做对，不看“补了多少函数”，而看下面三件事：

### 1. Host substrate 的语义是否明确

特别是：

- 哪些 HVA 可做 `virt_to_phys`
- 哪些内存保证物理连续
- 哪些映射只适用于 linear mapping

### 2. Runtime substrate 是否脱离 ArceOS 私有假设

特别是：

- `KernelGuardIf`
- `SpinNoIrq`
- `.percpu`
- task 调度与 waitqueue

### 3. Native hypervisor substrate 是否单独成面

特别是：

- `vcpu_run`
- VM exit
- G-stage
- 虚拟中断
- guest 状态

如果这三件事都没有单独成面，那么实现仍然是不稳定的。

---

## 七、当前推荐动作

基于现状，推荐下一步不是继续泛泛补 trait，而是直接做两件事：

1. 在实现侧先定义三层 facade 模块边界
2. 第一优先级实现 `host::mem`，把 guest RAM backing 语义闭合

因为只要 `host::mem` 这一层还没有解决：

```text
heap HVA -> HPA
连续物理 backing
G-stage map input
```

后面所有 runtime 和 vCPU 工作都还会继续被卡住。
