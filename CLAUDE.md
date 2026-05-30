# freehypervisor 项目规则

## 项目目标

研究 Hypervisor 与底层 OS 接口的真正交集（三者共需的 OS 功能），为 freehypervisor 设计提供技术参考。

## 分析对象

1. **KVM** (Linux 内核模块) — kvm.ko 需要 Linux 内核提供的所有功能
2. **Firecracker** (Linux 用户态 VMM) — 完整栈分析：KVM ioctl 子集 + 额外 Linux syscall
3. **bhyve** (FreeBSD 内核 vmm.ko + 用户态 bhyve(8)) — 基于 FreeBSD 14.x stable

## 分析深度

与现有 KVM 分析相同深度：源码级别的详细分析，~880 行规模，50+ 接口覆盖。

## 文件组织规则

- 源码放置在 `code/` 下，按 hypervisor 分子目录
- 分析文档放在 `docs/` 下，按 hypervisor 分子目录
- 对比文档放在 `docs/` 目录下
- 所有分析文档使用中文撰写

## 禁止行为

- 不要将大文件（>100MB）提交到 git
- 不要在文档中过度使用 emoji
