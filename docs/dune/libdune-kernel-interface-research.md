# libdune 内核接口依赖调研（dune.ko vs KVM）

调研目标（用户定义）：libdune 是一个 non-root-mode 库，把用户程序跑在 VMX non-root 的
内核态（ring 0）。搞清它依赖 `dune.ko` 还是 KVM、需要哪些内核接口、能否映射到我们
`axvisor_kvm.ko` 的 ABI。本轮只做源码级调研，不实跑。

参考来源：
- 原始 Dune（ix-project/dune，OSDI'12，Belay et al.）：`kern/`（dune.ko）+ `libdune/`。
- vusec/dune、rcslab/dune：活跃 fork。
- loongson-dune（Martins3）：**基于 KVM 的 Dune 重实现**——与本项目最相关。
- OSDI'12 论文《Dune: Safe User-level Access to Privileged CPU Features》。

## 1. Dune 的核心模型：虚拟化角色反转

正常虚拟化：VMX root = hypervisor，VMX non-root = guest OS。
Dune 把这个模型反转，用来给**普通进程**安全访问特权 CPU 特性（页表、ring、中断、TLB 等）：

- **VMX root**：跑 Linux 内核（因为它需要执行 VT-x 指令）。
- **VMX non-root**：跑普通进程本身。进程内部再分 ring0/ring3：
  - non-root ring0：libDune（库操作系统，处理特权指令、syscall 转发、缺页）。
  - non-root ring3：应用代码。

关键：VMX non-root **自带一整套特权环**。所以进程在 non-root 里可以合法地跑 CR3 切换、
`iret`、读写页表 supervisor 位、装 IDT 等特权指令，而不会危害 host 内核——因为一旦触发
VM-exit，控制权回到 root 侧的 dune.ko。这就是"把 user program 跑在 non-root 的内核态"的含义。

与 gVisor 的 KVM platform 对比：两者都把"自己的代码"放进 VMX non-root，但
- gVisor 借 `/dev/kvm` 现成 KVM API（CREATE_VM/VCPU/RUN...），guest 侧是 Sentry；
- 经典 Dune 用**自己的 `dune.ko`**（不是 KVM），guest 侧是被 dune 化的普通进程。

## 2. 经典 Dune 的内核接口：`/dev/dune` + 两个 ioctl（不是 KVM）

经典 Dune **不使用 `/dev/kvm`**。它有独立的内核模块 `dune.ko`（约 2500 行），暴露 `/dev/dune`
字符设备，只有两个核心 ioctl：

| ioctl | 定义方式 | 作用 |
|---|---|---|
| `DUNE_CONFIG` | `_IOR`/`_IOWR` | 配置 VMX 状态（VMCS、EPT、寄存器、入口点），准备进入 Dune 模式 |
| `DUNE_ENTER` | `_IOR` | 真正切入 VMX non-root，从 `dune_config.rip` 开始执行 |

（不同 fork 里两者可能合并为一个 `DUNE_ENTER` 直接吃 `struct dune_config`。）

### `struct dune_config` 布局（来自 `libdune/dune.S` 偏移常量）

```
offset 0  : rip   (DUNE_CFG_RIP)   —— non-root 侧入口地址（通常 = &__dune_ret）
offset 8  : rsp   (DUNE_CFG_RSP)   —— non-root 侧栈指针
offset 16 : cr3   (DUNE_CFG_CR3)   —— non-root 侧页表基址（进程自建的 pgroot 物理地址）
offset 24 : ret   (DUNE_CFG_RET)   —— 返回值/退出码
```

`libdune/entry.c` 的 `dune_init()`/`dune_enter()` 流程：
1. 进程自己在普通内存里建一套页表（`pgroot`）；
2. `open("/dev/dune")`；
3. 填 `conf.rip=&__dune_ret; conf.rsp=0; conf.cr3=phys(pgroot)`；
4. `__dune_enter(dune_fd, &conf)` → `ioctl(fd, DUNE_ENTER, &conf)`。

内核侧 `kern/vmx.c` 收到后：建 VMCS、装 EPT、把 `conf.cr3` 灌进 guest CR3、把 `conf.rip/rsp`
灌进 guest RIP/RSP，然后 `VMLAUNCH` 进 non-root。此后进程的每次"进内核"都表现为 VM-exit，
dune.ko 拦截并处理（缺页、syscall、HLT 让核）。

### syscall 语义（与 shim 无关，但影响移植）

进程在 non-root 里跑 `syscall`/`int 0x80` **只在进程自己内部 trap**（因为 non-root 有自己的
ring），不产生 VM-exit。要调 host 内核 syscall 必须用 **`VMCALL`（hypercall）**，dune.ko 把
VMCALL 路由到内核 syscall 表。可选的 patched glibc 直接发 VMCALL 加速。

## 3. 与 axvisor_kvm.ko 的关系：接口不同源，不能直接跑

经典 Dune 的 ABI（`/dev/dune` + `DUNE_CONFIG`/`DUNE_ENTER` + `struct dune_config`）
**与 KVM ABI 完全不同源**：

- 它没有 `KVM_CREATE_VM`/`KVM_CREATE_VCPU`/`KVM_SET_USER_MEMORY_REGION`/`KVM_RUN` 的概念；
- 它一步 `DUNE_ENTER` 直接把当前进程线程切进 non-root，没有独立 vCPU fd；
- 内存不走 `SET_USER_MEMORY_REGION` slot，而是直接拿进程自建页表的 `cr3` + EPT 反射进程 VMA。

因此 **libdune 不能像 gVisor/Firecracker 那样直接跑在 `axvisor_kvm.ko` 上**。要在本项目里
支持它，有三条路（按代价排序）：

1. **单独实现 dune.ko 兼容层**（最忠实）：在 `axvisor_kvm.ko` 旁另开一个 `/dev/dune` 或在同
   模块内加 `DUNE_CONFIG`/`DUNE_ENTER` ioctl，复用底层 axvm 的 VMX/EPT 原语（bind/VMPTRLD/
   VMLAUNCH），把 `dune_config.{rip,rsp,cr3}` 直接灌进 VMCS。工作量中等，但 ABI 独立。
2. **用 KVM-based Dune 变体**（最省力，推荐调研方向）：见 §4，loongson-dune 已经把 Dune 语义
   重写在 KVM API 之上。若采用它，libdune 场景就退化成"又一个用 `/dev/kvm` 的用户态程序"，
   直接落到我们已经在测的 gVisor/Firecracker 同一条兼容线上。
3. **不移植，仅作对照**：把 Dune 作为"OS 接口交集"研究里的一个反例（一个不走 KVM 的
   VMX non-root 消费者），说明 hypervisor-OS 接口并非只有 KVM 一种形态。

## 4. KVM-based Dune 变体（关键发现，决定移植可行性）

**loongson-dune**（github Martins3/loongson-dune）：明确描述为 "Process virtualization based on
KVM. More useable, stable and practical than Stanford Dune."

意义：它把经典 Dune 的 `dune.ko` 自定义 ioctl **替换成标准 KVM ioctl 序列**
（CREATE_VM → SET_USER_MEMORY_REGION → CREATE_VCPU → SET_SREGS(灌 cr3) → SET_REGS(灌 rip/rsp)
→ RUN）。如果 libdune 走这个变体：

- 它需要的 KVM ioctl 面 ≈ gVisor KVM platform 的子集（见
  `docs/gvisor/gvisor-kvm-ioctl-compat.md`）：CREATE_VM/VCPU、SET_USER_MEMORY_REGION、
  SET/GET_REGS、SET/GET_SREGS、SET_CPUID2、RUN，加上一个抢占/退出原语；
- 我们 shim 的兼容缺口与 gVisor 相同（重点是 `KVM_INTERRUPT`/exit 语义），一旦为 gVisor 补齐，
  libdune(KVM 变体) 大概率同样能跑。

待核实（下一轮，如需实跑再做）：loongson-dune 到底用不用 `KVM_INTERRUPT`/`KVM_NMI`、
是否依赖 EPT violation 反射进程 VMA（我们的 axvm EPT 模型能否满足）。

## 5. 结论

1. **经典 Dune（ix-project/vusec/rcslab）依赖独立的 `dune.ko` + `/dev/dune`，不是 KVM。**
   其 ABI 只有 `DUNE_CONFIG`/`DUNE_ENTER` 两个 ioctl + `struct dune_config{rip,rsp,cr3,ret}`，
   与 `axvisor_kvm.ko` 的 KVM ABI 不同源，**不能直接跑在我们的 shim 上**。
2. 若要在本项目测 libdune，最省力路线是 **KVM-based Dune 变体（loongson-dune）**，它把 Dune
   语义架在标准 KVM API 上，兼容缺口与 gVisor 同族——**应先解决 gVisor，再顺带验证它**。
3. 用户明确"先调研不必先跑 libdune"——本调研已足够定位方向：优先级 = 先跑 gVisor（KVM 兼容线），
   libdune 归入 KVM-based 变体一并处理，经典 dune.ko 路线仅在需要"忠实复现 Dune"时才单独做。
4. libdune 的独特价值（对项目"OS 接口交集"研究）：它证明"hypervisor↔OS 接口"存在 KVM 之外的
   第二形态（`/dev/dune` 直接 non-root 进入，无 vCPU fd、无 memory slot），可作为交集分析的对照点。
