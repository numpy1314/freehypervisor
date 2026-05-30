# Hypervisor-OS 最小接口交集研究计划（初版草稿）

## 研究目标

分析三种 Hypervisor 与底层 OS 的接口，找出它们的最小交集，
为 freehypervisor 的设计提供技术参考。

## 待分析的 Hypervisor

1. **KVM** (Linux) — Linux 内核模块，分析 kvm.ko 需要 Linux 内核提供的所有功能
2. **Firecracker** (Linux/KVM) — 用户态 VMM，分析其通过 KVM + Linux 系统调用的完整接口
3. **bhyve** (FreeBSD) — FreeBSD 内核 vmm.ko + 用户态 bhyve(8)，分析其对 FreeBSD 的接口依赖

## 分析维度

每个 Hypervisor 从以下维度分析其对 OS 的接口依赖：
- 内存管理
- 虚拟 CPU 管理
- I/O 设备模型
- 中断与定时器
- 进程/线程调度
- 其他依赖

## 产出物

- 源码放在 code/ 下，按 hypervisor 分子目录
- 分析文档放在 docs/ 下，按 hypervisor 分子目录
- 一份对比总结文档放在 docs/ 下
- 项目规则写入 CLAUDE.md

## 输出结构

code/
  kvm-linux-reference/
  firecracker-reference/
  bhyve-reference/
docs/
  kvm/
    kvm_linux_interface_analysis.md
  firecracker/
    firecracker_linux_interface_analysis.md
  bhyve/
    bhyve_freebsd_interface_analysis.md
  hypervisor_interface_comparison.md
CLAUDE.md
