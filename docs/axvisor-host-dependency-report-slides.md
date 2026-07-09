---
marp: true
theme: default
paginate: true
size: 16:9
title: AxVisor on Asterinas and Linux
---

# AxVisor 在 Asterinas 和 Linux 上的适配

## 我们到底做了什么

- 不是做一个比 `KVM` 更快的东西
- 而是想搞清楚：

> 一个 hypervisor 跑起来，到底依赖宿主 OS 的哪些能力

---

# 为什么要做这个

- 现在很多 hypervisor 都和某个宿主绑得很深
- 看起来是“移植一下”
- 实际上经常不知道它到底依赖了什么

所以我们的目标是：

- 把这些依赖拆出来
- 看哪些是通用能力
- 看哪些地方真的卡宿主语义

---

# 我们的方法

拿 `AxVisor` 做对象，

分别放到两个宿主里看：

- `Asterinas`
- `Linux`

如果两个宿主都要补同一类东西，
说明这可能是 hypervisor 的真实共性依赖。

如果只在某一边卡住，
说明问题更可能是宿主语义或集成方式。

---

# 我们把依赖分成三类

1. **宿主基础能力**
   - 内存、时间、中断、console 这些

2. **运行时能力**
   - task、wait queue、percpu、调度这些

3. **虚拟化执行能力**
   - VM/vCPU、guest memory、VM exit、虚拟中断这些

这比只看 API 名字更接近真实问题。

---

# 一个很重要的发现

问题往往不在“少了一个函数”，
而在“语义不一样”。

最典型的例子就是：

- guest 内存怎么分配
- 分到的是不是连续物理内存
- `virt_to_phys` 到底对什么地址有效

这类问题补接口没用，得改理解。

---

# Asterinas 这边说明了什么

在 Asterinas 上，
我们最先碰到的真实问题不是 VM exit，
也不是某个 trap 细节，
而是：

> guest RAM backing 语义不等价

这说明 hypervisor 迁移最先暴露的，
常常是宿主内存模型，不是虚拟化指令本身。

---

# Linux 这边说明了什么

在 Linux 上，
我们已经把：

- 模块编译
- rootfs
- QEMU 启动
- `insmod`
- `vm create`

这条链基本打通了。

但同时也暴露出另一个问题：

> AxVisor 作为 Linux 模块拿不到裸机启动时那份 DTB

---

# DTB 问题本质是什么

不是：

- `KVM` 不行
- `QEMU` 不行

而是：

- `QEMU` 把 DTB 给了 Linux
- Linux 用它把自己启动起来
- AxVisor 作为后加载模块，没有自动拿回这份信息

所以这是一个 **Linux 集成问题**。

---

# 这项工作的主要贡献

1. 我们把 AxVisor 对宿主的依赖拆开了
2. 我们证明了迁移难点常常在语义，不在 API 数量
3. 我们用 Asterinas 和 Linux 两边做了交叉验证

换句话说，
我们不是在证明“哪个更快”，
而是在证明：

> hypervisor 对宿主 OS 的依赖是可以被分析、分类和替换的

---

# 这项工作的意义

它的意义不在于替代 `KVM`，
而在于回答一个更基础的问题：

> 如果宿主不是 Linux，hypervisor 还需要什么东西才能活下来？

这件事对：

- 新型 OS
- Rust OS
- library OS / unikernel
- 可移植 hypervisor

都很重要。

---

# 一句话总结

这项工作的核心不是“移植 AxVisor”，
而是：

> 把 hypervisor 对宿主 OS 的隐式依赖，变成显式、可验证的能力边界。

