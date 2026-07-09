# Linux 连续内存接口缩减结论与实施记录

## 实施状态

已完成缩减并验证通过。

- Linux adapter 源码和构建产物中已经没有
  `alloc_contiguous_frames` / `dealloc_contiguous_frames` /
  `AXVISOR_MEM_CONTIG`。
- `MemoryIf` 已收敛为单页 `alloc_frame` / `dealloc_frame` 加地址转换。
- `axvm::hal::PagingHandlerImpl` 对多页 `alloc_frames` 请求只接受
  `num == 1`，RISC-V64 页表路径仍按单页页表页工作。
- host FDT staging 已从“物理连续 buffer”改为“虚拟连续 bytes provider”。
- 验证命令 `tools/verify-riscv-linux-host-linux-smoke.sh` 已通过，结果为
  `AXVISOR_SMOKE_PASS=1`。

## 结论

Linux 侧可以不再把“大块连续物理内存分配/释放”作为必须实现能力。

但这不是把 `alloc_contiguous_frames()` 的内部实现改成循环
`alloc_frame()`。现有接口返回的是一个首 HPA，调用者有权把
`[paddr, paddr + num_frames * 4K)` 当作真实连续物理区间使用。用散页冒充
连续 HPA 会破坏接口契约。

可行的缩减方向是：

- 从 Linux 侧外部胶水中删除 `alloc_contiguous_frames` /
  `dealloc_contiguous_frames` 两个强制接口。
- 保留并强化 `alloc_frame` / `dealloc_frame`。
- 把所有多页内存需求改成逐页分配、逐页映射、逐页释放。
- 对只需要 CPU 侧连续访问的对象，使用 Linux 虚拟连续内存，而不是物理连续
  内存。

## 现有接口语义

`axvisor_api::memory::MemoryIf` 当前定义的是“连续物理页帧”：

- `alloc_contiguous_frames(num_frames, frame_align)` 返回第一帧的物理地址。
- `dealloc_contiguous_frames(first_addr, num_frames)` 要求地址和页数匹配之前的
  连续分配。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_api/src/memory.rs`
- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-page-table-multiarch/src/lib.rs`

Asterinas 侧也是这个语义。它用 `FrameAllocOptions::alloc_segment()` 分配
`HostMemory::Segment`：

- `ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs`

所以这个接口的原始语义不是“分配 N 个页”，而是“分配一段可由首地址线性描述的
连续 HPA”。

## 修改前 Linux 实现

Linux shim 修改前确实专门实现了物理连续分配：

- `alloc_frame()` 使用 `alloc_pages(..., 0)`。
- `alloc_contiguous_frames()` 使用 `alloc_pages(..., order)` 或
  `alloc_pages_exact()`。
- `dealloc_contiguous_frames()` 按连续分配记录释放。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_shim.c`

这两个函数就是三十个接口里最适合作为“缩减目标”的一对，因为 Linux 作为
loadable module 不适合承诺稳定提供大块连续物理内存。当前实现已经删除这两个
函数。

## 当前调用点分类

### 1. RISC-V64 页表路径

可替代。

`PageTable64` 创建根页表和下级页表时只调用 `alloc_frame()`，释放时也只调用
`dealloc_frame()`。RISC-V64 当前路径不需要多页连续页表内存。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-page-table-multiarch/src/bits64.rs`

### 2. 32-bit ARM 页表路径

不可在原语义下直接替代，但不影响当前 RISC-V64 Linux host 目标。

`PageTable32` 的 ARM 路径需要 16KB 对齐 L1 页表，会调用
`alloc_frames(4, 16384)`。如果未来要支持 ARM32，这条路径需要保留连续分配，
或者重写页表 backend。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-page-table-multiarch/src/bits32.rs`

### 3. Guest RAM `MapAlloc`

已经是逐页模型。

`Backend::map_alloc(populate=true)` 对 guest RAM 是按 `PageIter4K` 逐页
`alloc_frame()`，然后逐页 `pt.map()`。释放时逐页 `pt.unmap()` +
`dealloc_frame()`。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axaddrspace/src/address_space/backend/alloc.rs`

### 4. Guest RAM `MapLinear` / `MapReserved` / `MapIdentical`

不能用散页冒充。

`map_linear()` 明确按 `phys_start + offset` 建映射，要求 HPA 区间真实连续。
这类路径只能使用真实保留物理区、host DTB 中的 reserved-memory、或者设备
passthrough 区间，不能由逐页 `alloc_frame()` 伪造。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axaddrspace/src/address_space/backend/linear.rs`

### 5. Host FDT staging

可替代。

早期 Linux shim 把 `host_fdt_path` 读出的 DTB 作为可由
`host_fdt_paddr()` 间接访问的对象暴露给 AxVisor core。当前实现已经去掉 Linux
侧的 `host_fdt_paddr` 胶水，只保留虚拟连续的 `host_fdt_vaddr/host_fdt_size`
provider。

但 `try_get_host_fdt()` 的真实需求只是得到一个可解析的连续字节 slice：

- `host_fdt_bytes()`
- 读 FDT header
- 按 `total_size` 构造 `&[u8]`

这不是 DMA 场景，也不是 guest 直接访问场景。因此这块已经改成“Linux 虚拟连续
host FDT buffer”，不需要真实物理连续。

对应源码：

- `linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_shim.c`
- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_core/src/vmm/fdt/parser.rs`

## 推荐替代方案

### 方案 A：RISC-V64 Linux host 专用缩减

这是当前已实施方案。

1. `MemoryIf` 不再要求 Linux backend 提供多页连续分配。
2. `PagingHandlerImpl::alloc_frames(num, align)` 在 RISC-V64 Linux build 中只允许
   `num == 1`，否则返回 `None` 或编译期不可达。
3. `PagingHandlerImpl::dealloc_frames(paddr, num)` 在 RISC-V64 Linux build 中只允许
   `num == 1`，转发到 `dealloc_frame()`。
4. host FDT staging 改为虚拟连续 buffer：
   - C 侧用 `kvzalloc()` 或逐页 `alloc_page()` + `vmap()` 保存 DTB。
   - 不再要求这个 buffer 有连续 HPA。
   - Rust/API 侧新增或替换为 `host_fdt_vaddr/host_fdt_len`，或者新增
     `ArchIf::host_fdt_bytes()`，让 core 直接拿 `&'static [u8]`。

这个方案已经把 Linux 侧必须实现的三十个接口减少 2 个：

- 删除 `MemoryIf::alloc_contiguous_frames`
- 删除 `MemoryIf::dealloc_contiguous_frames`

### 方案 B：通用上游接口收缩

这是更彻底但影响更大的方案。

1. 从公共 `MemoryIf` 中移除 contiguous allocation。
2. 页表库 `PagingHandler` 改为单页接口：
   - `alloc_frame()`
   - `dealloc_frame()`
   - `phys_to_virt()`
3. 对确实需要连续物理内存的组件新增单独 trait，例如：
   - `DmaMemoryIf`
   - `ContiguousMemoryIf`
   - `ReservedMemoryIf`
4. 只有具体平台声明支持该 trait 时，相关功能才启用。

这个方案更符合跨 OS 抽象，但会影响 Asterinas、ArceOS、Linux bridge 以及
32-bit ARM 页表路径。

## 不可采用的方案

不能在 Linux shim 中这样做：

```text
alloc_contiguous_frames(num):
    pages = [alloc_frame(); num]
    return pages[0].paddr
```

原因：

- `paddr + 4K` 不等于第二个散页的 HPA。
- `phys_to_virt(paddr + offset)` 会落到错误页面或失败。
- `map_linear(gpa, paddr, len)` 会把不存在的连续物理区间映射给 guest。
- `dealloc_contiguous_frames(first_addr, num)` 无法仅凭首地址表达散页列表，除非另建
  隐式对象表；即使有对象表，也无法修复上层 `paddr + offset` 的语义错误。

## 最终判断

对当前目标“在 Linux 上运行 AxVisor 并启动 RISC-V64 Linux guest”来说，连续内存
分配/释放接口可以被取代。

取代方式不是保留原函数名并改内部实现，而是：

- 多页普通内存全部走逐页 `alloc_frame/dealloc_frame`。
- 线性 HPA 映射只接受真实 reserved/identical 物理区。
- host FDT 从“物理连续 buffer”改为“虚拟连续 bytes provider”。
- 公共接口层把 contiguous allocation 从必选能力降为可选能力或平台扩展能力。

因此，这对接口是当前三十个接口中可以明确缩减的对象；host FDT provider 改造和
RISC-V64 页表 handler 的单页化约束已经完成，并通过 Linux guest smoke 验证。
