# Phase 2: 修复 Axvisor Guest Memory Backing 语义不等价

## Goal Description

Phase 1 已经证明两件事：

1. `axvisor_api` 的组件层 trait 可以在 Asterinas 上实现并通过最小探针。
2. 完整 Axvisor runtime 可以在 Asterinas 上启动，且已经进入到 `config::init_guest_vm()`。

当前真实阻塞点已经重新定位，不再是早先怀疑的 `hcounteren` 或 `KernelGuardIf`：

- runtime 路径能通过 `enable_virtualization()`
- 能通过 `handle_fdt_operations()`
- 能创建 `VM`
- 卡在 `vm_alloc_memorys()` 的第一块 guest RAM 分配

更具体地说，停点在：

```rust
axvm::AxVM::alloc_memory_region(layout, Some(gpa))
```

其内部路径是：

```rust
alloc_zeroed(layout)
  -> HostVirtAddr
  -> axvisor_api::memory::virt_to_phys(hva)
  -> address_space.map_linear(gpa, hpa, len, perms)
```

这条路径在 ArceOS 能成立，但在 Asterinas 上有两个默认假设同时失效：

1. **返回的 HVA 可以直接反查为 HPA**
2. **整段 HVA backing 对应一段物理连续 HPA**

而 Asterinas 当前实现里：

- `ostd::hypervisor::virt_to_phys()` 实际走的是 `ostd::mm::kspace::vaddr_to_paddr()`
- 该函数只接受 **linear mapping 区** 的虚拟地址
- `alloc_zeroed(64 MiB)` 返回的是 **heap / vmalloc 区地址**
- Asterinas 的 heap / VMO 语义允许“虚拟连续、物理不连续”

所以当前阻塞不是“少几个 runtime 函数”，而是：

> Axvisor 默认 guest memory backing 语义与 Asterinas 的 host memory 语义不等价。

---

## Root Cause

### 1. `virt_to_phys()` 的地址域不等价

Axvisor/ArceOS 路径默认允许：

```text
任意可用的 host kernel HVA -> 反查 HPA
```

但 Asterinas 当前只保证：

```text
linear-mapped HVA -> HPA
```

对 heap / vmalloc 地址直接调用 `virt_to_phys()`，语义上就是未满足前提。

### 2. `map_linear()` 要求物理连续 backing

`axvm::alloc_memory_region()` 在拿到一个 `hpa` 后，直接执行：

```rust
map_linear(gpa, hpa, layout.size(), ...)
```

这隐含要求：

```text
[hpa, hpa + len) 是一段连续物理区间
```

但 Asterinas 的 heap 分配只保证：

```text
HVA 连续
```

并不保证背后的 HPA 连续。

因此，即使把 `virt_to_phys(heap_hva)` 勉强做成可用，也仍然不足以修复整个路径。

---

## Acceptance Criteria

- AC-1: Axvisor runtime 不再卡在 `vm_alloc_memorys()`
  - Positive Tests:
    - 日志出现 `alloc_memory map_alloc done`
    - 后续进入 `load_images`
  - Negative Tests:
    - 不允许依赖 heap/vmalloc 地址直接喂给只支持 linear mapping 的 `virt_to_phys`

- AC-2: Guest RAM backing 语义显式对齐
  - Positive Tests:
    - Guest RAM 的 host backing 明确满足“可取 HPA + 物理布局语义明确”
    - `map_linear()` 的输入与 backing 语义一致
  - Negative Tests:
    - 不允许继续隐式假设“任意 heap HVA 对应连续 HPA”

- AC-3: 完整 runtime 至少执行到 `ImageLoader::load()`
  - Positive Tests:
    - 日志出现 `init_guest_vm load_images`
    - 若后续再失败，失败点已从 guest memory allocation 前移

---

## Recommended Fix Order

### M1: 先明确选择哪一种 backing 语义

必须先做架构选择，不能继续混用：

#### 方案 A：保持 `axvm::map_linear()` 语义不变

要求：

- guest RAM 必须由 **物理连续内存** 提供 backing
- 返回给 Axvisor 的 HVA 必须来自 **linear mapping 区**

实现方式：

- 从 frame/segment allocator 分配连续物理区
- 用 `phys_to_virt()` 得到 linear-mapped HVA
- 后续 `virt_to_phys()` 和 `map_linear()` 都继续成立

优点：

- 改动范围最小
- 最符合“最快速径”

缺点：

- 依赖连续物理内存供应
- 大内存 VM 扩展性一般

#### 方案 B：允许 guest RAM backing 物理不连续

要求：

- 不再使用 `map_linear(gpa, hpa, len)` 直接覆盖整段
- 改成按页或按 segment 建立 GPA -> HPA 映射

优点：

- 更符合 Asterinas 的 VMO/heap 语义
- 长期更稳

缺点：

- 需要改 Axvisor/axvm memory region 建模
- 不属于“最快速径”

**当前建议**：优先走 **方案 A**，先跑通完整 runtime。

### M2: 把 guest RAM allocation 从 heap 改成 frame-backed

最小落点应满足：

- 不再走 `alloc_zeroed(layout)` 作为 guest RAM backing
- 改为“先拿物理 backing，再映射出 HVA”

如果不改这一步，后面的 `virt_to_phys()`、`map_linear()`、image load 都没有可靠基础。

### M3: 跑到 `load_images` / `vm.init`

当 guest RAM backing 语义修正后，再继续验证：

1. `ImageLoader::load()`
2. `vm.init()`
3. `setup_vm_primary_vcpu()`
4. `vmm::start()`

---

## Non-Goals

本阶段不处理：

- guest timer/IRQ 注入语义
- `irq_handler()` stub 是否影响后续 VM exit
- vCPU run loop 内的 timer interrupt / `Nothing` exit
- 多 VM / 多 vCPU 扩展

这些都排在 guest memory backing 正确之后。

---

## Current Conclusion

当前最重要的结论是：

> “Asterinas 已经把 Axvisor 跑到了完整 runtime 初始化阶段；真正阻塞它的，不是组件 trait 缺口，而是 guest memory backing 路径与 ArceOS 语义不等价。”

这也是 Phase 2 应该围绕的唯一主线。
