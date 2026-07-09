# Axvisor on Asterinas: Guest Memory Backing 语义不等价

## 结论

完整 Axvisor runtime 在 Asterinas 上的首个真实阻塞点，不在 `vmexit_handler`，也不在 `hcounteren`，而在 **guest RAM 建立阶段**。

定位后的调用链：

```text
runtime::run
  -> config::init_guest_vm
    -> handle_fdt_operations               // 已通过
    -> VM::new                             // 已通过
    -> vm_alloc_memorys
      -> axvm::alloc_memory_region         // 卡在这里
```

进一步展开：

```rust
pub fn alloc_memory_region(&self, layout: Layout, gpa: Option<GuestPhysAddr>) -> AxResult<&[u8]> {
    let hva = alloc::alloc::alloc_zeroed(layout);
    let hpa = axvisor_api::memory::virt_to_phys(hva);
    address_space.map_linear(gpa, hpa, layout.size(), ...)?;
}
```

这个实现对 host 提出了两个隐含要求：

1. `alloc_zeroed(layout)` 返回的 HVA 可以直接转换成 HPA
2. 这段 HVA 背后是一段 **物理连续** 的内存

在 ArceOS 上，这两个要求默认成立或足够接近成立。

在 Asterinas 上，这两个要求都不成立。

---

## Asterinas 当前语义

### 1. `virt_to_phys()` 只支持 linear mapping 地址

当前 Asterinas hypervisor adapter 最终调用：

```rust
ostd::hypervisor::virt_to_phys(vaddr)
  -> ostd::mm::kspace::vaddr_to_paddr(vaddr)
```

而 `vaddr_to_paddr()` 的约束是：

```text
输入必须位于 LINEAR_MAPPING_VADDR_RANGE
```

heap / vmalloc 地址不在这个范围内。

### 2. heap / VMO 只保证虚拟连续

Asterinas 的 VM/heap 体系允许：

- 虚拟地址连续
- 物理页离散

这和 `map_linear(gpa, hpa, len)` 需要的“整段 HPA 连续”不是一回事。

所以即使将来补了“任意 HVA -> HPA 查询”，也只能得到：

```text
第一页 HPA
```

不能自动推出：

```text
整段 [hpa, hpa + len) 连续
```

---

## 为什么这不是“小接口没实现”

这次定位非常关键，因为它把问题性质从：

```text
API surface 不完整
```

变成了：

```text
内存语义模型不等价
```

也就是说，哪怕把所有 ArceOS runtime 函数名都一一补齐，只要 guest RAM 仍然走：

```text
heap HVA -> virt_to_phys -> map_linear
```

runtime 依然会在这里挂住。

---

## 两种修复路线

### 路线 1：保持 Axvisor 现有假设，改 Asterinas backing 方式

做法：

- guest RAM 不再从 heap 分配
- 改成分配 **物理连续** frame/segment
- 再通过 `phys_to_virt()` 获得 linear-mapped HVA

这样可以继续兼容：

```text
virt_to_phys(hva)
map_linear(gpa, hpa, len)
```

优点：

- 改动小
- 适合快速跑通

缺点：

- 强依赖连续物理内存

### 路线 2：保留 Asterinas 现有内存语义，改 Axvisor memory region 模型

做法：

- 允许 backing 为非连续页
- 不再对整段 memory region 使用一次 `map_linear`
- 改成逐页或逐 segment 建立 GPA -> HPA 映射

优点：

- 更符合 Asterinas 现有设计
- 长期更稳

缺点：

- 改动范围大
- 不适合当前“最快速径”

---

## 推荐判断

如果目标是“尽快把完整 Axvisor 在 Asterinas 上跑起来”，推荐优先选：

```text
路线 1：frame-backed / physically contiguous guest RAM
```

因为它最少触碰上游 Axvisor/axvm 的内存模型。

如果目标是长期把 Axvisor 做成真正跨底座的通用架构，那么最终还是应该走：

```text
路线 2：显式支持非连续 backing
```

---

## 对迁移计划的影响

这项发现直接修正了移植工作的优先级：

1. 先修复 guest memory backing 语义
2. 再看 image load / `vm.init()`
3. 再看 vCPU 运行和 VM exit
4. 最后才轮到 timer / IRQ 注入 / shell runtime 之类问题

所以当前不应该再把主要精力放在：

- `KernelGuardIf`
- `hcounteren`
- `irq_handler()` stub
- probe-only 的 `vmexit_handler` panic

这些都不是 full runtime 当前的首阻塞点。
