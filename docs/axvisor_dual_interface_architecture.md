# Axvisor 双接口架构建议

> 目标：把 Axvisor 从“绑定某个宿主 OS 的 hypervisor 实现”重构为“可同时适配不同宿主底座、不同虚拟化提供者”的通用架构。
>
> 本文的核心结论是：`host OS 适配` 和 `虚拟化执行面适配` 不是同一层问题，不应合并在一个 `host` 抽象里。

---

## 一、问题重述

当前讨论中有两条已有思路：

1. 把 host 依赖收敛到 `axvm::host`，由 `axvm` 内建多 host backend
2. 把 host contract 抽到独立 `axvisor-api`，由不同底座在外部实现

这两条路线都抓住了一个真实问题：Axvisor 需要从宿主侧获取一组能力，不能继续把这些能力散落在架构代码和底座代码里。

但这两条路线都还少拆了一层：

- 一类依赖是 **宿主底座 OS 提供的基础能力**
- 另一类依赖是 **虚拟化执行面提供的 VM/vCPU 控制能力**

如果不把这两类依赖拆开，Linux/KVM/QEMU 这类场景会持续把边界搞混：

- Linux 本身不是完整的 hypervisor provider
- `/dev/kvm` 才是 Linux 上的虚拟化执行面接口
- QEMU/Firecracker 不是宿主底座，而是建立在 `/dev/kvm` 之上的用户态 VMM 或设备模型

因此，单独讨论“Axvisor 对 OS 的依赖”是不够的，必须同时讨论“Axvisor 对 virtualization provider 的依赖”。

---

## 二、核心判断

推荐把 Axvisor 的外部依赖拆成两组接口：

1. `host-api`
2. `hv-provider-api`

其中：

- `host-api` 负责抽象宿主底座 OS 的通用能力
- `hv-provider-api` 负责抽象真正承载 VM/vCPU 生命周期和 guest 执行的虚拟化提供者

这两组接口的差异，不是实现细节差异，而是**架构边界差异**。

---

## 三、两类依赖的定义

### 3.1 `host-api`：宿主底座能力

这一层回答的问题是：

> “Axvisor 运行在某个 OS/底座之上时，需要这个底座提供哪些基础能力？”

典型内容包括：

- 物理内存分配、页表管理、地址翻译
- 定时器、时钟源
- 本地中断控制、IPI、IRQ 屏蔽
- 任务/线程/CPU 绑定
- 控制台、日志、文件或镜像加载
- 锁、原子、每 CPU 数据
- 平台初始化、CPU 上下文保存恢复

这一层的典型实现者：

- ArceOS adapter
- Asterinas adapter
- 其他 OS adapter

### 3.2 `hv-provider-api`：虚拟化执行面能力

这一层回答的问题是：

> “到底是谁提供 VM/vCPU 的创建、运行、退出、寄存器访问、中断注入和 guest memory 注册这些能力？”

典型内容包括：

- VM 创建、销毁
- vCPU 创建、销毁
- guest memory region 注册和撤销
- vCPU `run` / VM entry / VM exit 返回
- 通用寄存器和控制寄存器访问
- 中断注入、虚拟 irqchip
- MMIO/PIO trap 结果表达
- capability 探测
- dirty log、ioeventfd、irqfd 等扩展能力

这一层的典型实现者：

- Asterinas 原生 hypervisor backend
- ArceOS 原生 hypervisor backend
- Linux `/dev/kvm` backend
- FreeBSD `/dev/vmm` backend

---

## 四、为什么必须拆成两层

### 4.1 Linux/KVM/QEMU 的边界天然是三层

以 Linux 为例，真实分层不是“Linux = host”这么简单，而是：

```text
QEMU / Firecracker
        │
        ▼
    /dev/kvm
        │
        ▼
      Linux
```

其中：

- Linux 提供线程、内存、fd、epoll、timerfd、权限控制等通用宿主能力
- `/dev/kvm` 提供 VM/vCPU 控制和硬件虚拟化入口
- QEMU/Firecracker 在用户态做设备模型、控制面和部分策略

如果把这三层压成一个 `host` 抽象，会出现两个问题：

1. `host` 抽象会同时包含 OS 能力和 `/dev/kvm` 能力，边界变脏
2. QEMU 这种用户态设备模型会被误当成底座能力，而不是上层 VMM 组成部分

### 4.2 现有交集分析已经说明 VM/vCPU 控制是独立边界

仓库中的接口分析文档已经给出足够证据：

- [hypervisor_interface_comparison.md](/home/bullet1517/freehypervisor/docs/hypervisor_interface_comparison.md:43) 列出了 `KVM_CREATE_VM`、`KVM_CREATE_VCPU`、`KVM_RUN`、寄存器访问等能力，它们不是普通 OS 基础设施，而是 virtualization provider 的控制面接口。
- [hypervisor_interface_comparison.md](/home/bullet1517/freehypervisor/docs/hypervisor_interface_comparison.md:70) 和 [hypervisor_interface_comparison.md](/home/bullet1517/freehypervisor/docs/hypervisor_interface_comparison.md:90) 说明 MMIO/PIO trap、中断注入、事件通知都处在 guest 执行面边界。
- [hypervisor_os_interface_intersection.md](/home/bullet1517/freehypervisor/docs/intersection/hypervisor_os_interface_intersection.md:217) 到 [hypervisor_os_interface_intersection.md](/home/bullet1517/freehypervisor/docs/intersection/hypervisor_os_interface_intersection.md:260) 清楚区分了 VM/vCPU 生命周期、寄存器状态管理、CPUID/MSR 控制、VM exit 分发。

换句话说，现有研究本身已经证明：

> “虚拟化执行面”应该被当成一个独立 contract，而不是 `host-api` 的一个子模块。

### 4.3 对 Asterinas 原生迁移也有直接收益

对 Asterinas 迁移来说，`host-api` 和 `hv-provider-api` 目前可能都由 Asterinas 侧实现，但这不意味着它们应该在架构上合并。

原因很直接：

- 短期：同一仓库里由 Asterinas 一起实现，工程上最方便
- 长期：一旦需要接入 `/dev/kvm`、bhyve、其他 in-kernel backend，这两类能力会立刻分化

如果现在不拆，将来一定要做一次更痛苦的二次拆分。

---

## 五、推荐架构

### 5.1 总体结构

```text
                 ┌──────────────────────────┐
                 │       axvisor-core       │
                 │ VM runtime / manager /   │
                 │ shell / config / devices │
                 └────────────┬─────────────┘
                              │
              ┌───────────────┴────────────────┐
              │                                │
              ▼                                ▼
   ┌────────────────────┐          ┌────────────────────┐
   │      host-api      │          │  hv-provider-api   │
   │ OS substrate       │          │ virtualization     │
   │ abstraction        │          │ execution plane    │
   └─────────┬──────────┘          └─────────┬──────────┘
             │                               │
   ┌─────────┼─────────┐           ┌─────────┼──────────┐
   │         │         │           │         │          │
   ▼         ▼         ▼           ▼         ▼          ▼
 ArceOS   Asterinas  Other OS   Native    /dev/kvm   /dev/vmm
 adapter  adapter    adapter    backend   backend    backend
```

### 5.2 Linux/KVM/QEMU 对位

在 Linux 场景下，推荐按下面理解：

```text
axvisor-core
  ├─ host-api        -> Linux userspace host adapter
  │                    (thread, mmap, timerfd, event loop, fd, logging)
  └─ hv-provider-api -> KVM backend
                       (open /dev/kvm, create_vm, create_vcpu, run, regs, irqchip)

QEMU / Firecracker style device model
  -> 属于 axvisor-core 上层或其设备模型子系统
  -> 不是 host-api，也不是 OS substrate
```

这意味着：

- `/dev/kvm` 归 `hv-provider-api`
- `epoll`/`timerfd`/`pthread` 更接近 `host-api`
- virtio、block、net、MMIO 设备模型归 `axvisor-core` 或其上层设备子系统

### 5.3 Asterinas 对位

在 Asterinas 原生 hypervisor 场景下：

```text
axvisor-core
  ├─ host-api        -> Asterinas adapter
  └─ hv-provider-api -> Asterinas native hypervisor backend
```

这里两个实现都来自 Asterinas 一侧，但语义上仍是两层：

- 一个实现底座能力
- 一个实现 guest 执行面

---

## 六、与现有两条路线的关系

### 6.1 `axvm` 内建多后端路线

优点：

- 短期落地快
- 在单仓库内改动集中
- 对当前代码入侵小

问题：

- `axvm` 会同时承担 runtime、中间 glue、后端选择、OS 适配
- 新增底座或新增 provider 时，`axvm` 都要知道它们的存在
- 长期会把 `axvm` 演化成“上帝模块”

结论：

这条路线适合作为过渡实现，但不适合作为长期稳定边界。

### 6.2 `axvisor-api` 外置契约路线

优点：

- 更符合可移植目标
- `axvisor-core` 不必枚举具体底座
- 新增底座或 provider 的改动更局部

问题：

- 如果只有一个大而全的 `axvisor-api`，仍会把 OS substrate 和 virtualization provider 混在一起
- 结果只是把问题从 `axvm::host` 搬到一个更大的 API crate 里

结论：

这条路线更接近正确方向，但必须升级为：

- `axvisor-host-api`
- `axvisor-hv-provider-api`

至少要在逻辑上拆成两组 trait，即使物理上暂时仍在一个 crate 里，也应保持模块边界明确。

---

## 七、建议的 trait 分层

下面给出一版建议的逻辑分层。这里不追求最终 Rust 签名，只定义职责边界。

### 7.1 `host-api`

#### `MemoryIf`

负责：

- 页分配、释放
- 地址空间映射
- HVA/PA 转换
- pin / unpin 或等价的物理驻留保证
- TLB 刷新辅助

不负责：

- guest memory region 注册到 KVM 或其他 provider

#### `TimeIf`

负责：

- 单调时间读取
- 高精度定时器注册/取消
- delay / timeout 原语

不负责：

- guest TSC 或 guest time offset 的设置

#### `TaskIf`

负责：

- 创建 vCPU 所需执行上下文
- 调度、唤醒、休眠、绑定 CPU
- 本地 CPU ID 查询

不负责：

- VM entry / exit

#### `IrqIf`

负责：

- 本地中断屏蔽/恢复
- IPI 或等价 kick 机制
- host 侧中断路由辅助

不负责：

- 向 guest 注入虚拟中断

#### `PlatformIf`

负责：

- CPU feature 探测辅助
- 平台初始化
- 控制台、日志、设备树、镜像装载等底座能力

### 7.2 `hv-provider-api`

#### `VmIf`

负责：

- VM create / destroy
- capability 查询
- guest memory slot 注册/撤销
- irqchip / ioeventfd / irqfd 等 VM 级扩展

#### `VcpuIf`

负责：

- vCPU create / destroy
- `run() -> VmExit`
- kick / pause / resume
- 通用寄存器、控制寄存器、CSR/MSR 读写

#### `VmExitIf` 或统一 `VmExit` 枚举

负责表达：

- MMIO read/write
- PIO read/write
- page fault / nested page fault / guest page fault
- interrupt window
- halt / shutdown / reset
- hypercall / ecall
- internal error / fail entry

#### `GuestIrqIf`

负责：

- 注入虚拟中断
- 设置 irq line
- MSI/MSI-X 或架构相关中断入口

#### `GuestTimeIf`

负责：

- guest 可见时钟偏移
- TSC scaling / `htimedelta`
- timer virtualization 扩展

---

## 八、实现策略建议

### 8.1 短期策略

短期不必立刻拆成多个 crate，可以先：

1. 保留 `axvisor-api` 这个总名字
2. 在其中明确分成 `host` 与 `hv` 两个模块
3. 禁止跨层随意引用
4. 在 `axvisor-core` 中通过组合注入，而不是让 `axvm` 直接全局拿默认 host

即：

```text
axvisor-api
  ├─ host/
  └─ hv/
```

这样可以先修正架构边界，再决定是否物理拆 crate。

### 8.2 中期策略

中期建议变为：

```text
axvisor-host-api
axvisor-hv-provider-api
axvisor-core
axvisor-host-arceos
axvisor-host-asterinas
axvisor-hv-kvm
axvisor-hv-asterinas
```

这样新增 Linux/KVM 支持时，不需要污染 Asterinas/ArceOS 原生 backend 代码。

### 8.3 迁移现有 Asterinas 计划的方式

现有 [plan_axvisor_on_asterinas.md](/home/bullet1517/freehypervisor/docs/plan_axvisor_on_asterinas.md:38) 中的 `asterinas-vmm-shim` 可以继续存在，但建议重新定义为：

- `asterinas-host-adapter`
- `asterinas-hv-backend`

如果短期不想拆 crate，至少要在文档和模块上标注：

- 哪些函数属于宿主底座职责
- 哪些函数属于虚拟化执行面职责

例如：

- `hyp_pin_memory()` 更接近 `host-api`
- `hyp_vcpu_run()` 明显属于 `hv-provider-api`
- `hyp_inject_interrupt()` 更接近 `hv-provider-api`
- `hyp_timer_set()` 更接近 `host-api`

---

## 九、对当前决策的直接建议

### 9.1 不建议的做法

不建议继续把所有依赖统一称为“host 依赖”。

因为这样会导致：

- `/dev/kvm` 被误归类为底座 OS 能力
- QEMU/Firecracker 的位置不断漂移
- 原生 hypervisor backend 和 KVM backend 的差异无法被稳定表达

### 9.2 推荐决策

推荐采用：

1. **主路线选 `axvisor-api` 思路**
2. **把 contract 拆成 `host-api` + `hv-provider-api` 两层**
3. **`axvm` 不再承担所有 host/provider glue，而只保留 runtime 相关职责**

这意味着长期结构上应当是：

```text
axvisor-core / axvm
    ↑
composition root
    ├─ host adapter
    └─ hv provider backend
```

而不是：

```text
axvm
  └─ 内建所有 host/backend 选择逻辑
```

---

## 十、结论

一句话总结：

> 如果目标是“让 Axvisor 变成通用 OS 都能接受的形态”，那么正确的长期边界不是“一个统一 host 抽象”，而是“宿主底座接口 + 虚拟化提供者接口”的双接口模型。

对应到两条已有路线：

- `axvm` 内建多后端：适合作为短期工程路径
- `axvisor-api` 外置契约：更适合作为长期方向

但长期方向必须进一步升级为双接口模型，否则只是把耦合位置从 `axvm::host` 平移到一个更大的 API crate 中。

---

## 附：一句话对位表

| 实体 | 推荐归类 |
|------|----------|
| ArceOS | host substrate |
| Asterinas | host substrate |
| Linux | host substrate |
| `/dev/kvm` | virtualization provider |
| `/dev/vmm` | virtualization provider |
| QEMU | 用户态 VMM / 设备模型 |
| Firecracker | 用户态 VMM，调用 KVM provider |
| bhyve 用户态部分 | 用户态 VMM / 设备模型 |
| bhyve 内核 `vmm.ko` | virtualization provider |
