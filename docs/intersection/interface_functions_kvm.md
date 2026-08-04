# KVM (Linux) 侧 36 接口函数级抽取

> 目标：为 36 个 hypervisor↔OS 接口逐个抽取 KVM（Linux）侧的真实函数名 + 源码片段。
> 源码来源：本仓库参考树 `code/kvm-linux-reference/`（Linux 6.x）。
> 每条给出：函数名 / 源码位置（相对路径:行号）/ 源码片段（≤25 行）/ 一句话语义。
> 说明：KVM 是内核模块，virtio/网络后端/块设备/事件循环/进程沙箱等由用户态 QEMU 承载，
> 不在本内核参考树内——凡此类接口如实注明"KVM 内核侧不实现，由用户态 QEMU 承载"。

---

## 维度 1：内存管理

### 1) Guest 内存分配与映射

- 函数名：`kvm_set_memory_region()`；GFN→memslot：`gfn_to_memslot()`；GFN→HVA：`gfn_to_hva()` / `gfn_to_hva_memslot()`
- 源码位置：`virt/kvm/kvm_main.c:1994`（设置 memslot）、`:2628`（查 memslot）、`:2734` / `:2741`（GFN→HVA）

```c
// virt/kvm/kvm_main.c:1994
static int kvm_set_memory_region(struct kvm *kvm,
				 const struct kvm_userspace_memory_region2 *mem)
{
	struct kvm_memory_slot *old, *new;
	enum kvm_mr_change change;
	int as_id, id, r;

	lockdep_assert_held(&kvm->slots_lock);
	r = check_memory_region_flags(kvm, mem);
	if (r) return r;
	as_id = mem->slot >> 16;
	id = (u16)mem->slot;
	/* 对齐 / access_ok / 重叠检查 ... */
	/* 最终 r = kvm_set_memslot(kvm, old, new, change); */
}

// virt/kvm/kvm_main.c:2741
unsigned long gfn_to_hva(struct kvm *kvm, gfn_t gfn)
{
	return gfn_to_hva_many(gfn_to_memslot(kvm, gfn), gfn, NULL);
}
```

一句话：用户态 VMM 通过 `KVM_SET_USER_MEMORY_REGION` ioctl 把一段用户内存登记为 guest 物理地址空间的 memslot；查询链把 GPA(GFN) 映射回 host 虚拟地址(HVA)。KVM 只做 GPA↔HVA 登记，真正的物理页由 host mm 按需分配。

### 2) 页面锁定 / 防换出

- 函数名：`hva_to_pfn_fast()` / `hva_to_pfn_slow()`，内部调用 `pin_user_pages_fast()` / `pin_user_pages_unlocked()`；解锁 `unpin_user_page()`
- 源码位置：`virt/kvm/kvm_main.c:2867`（fast pin）、`:2901`（slow pin）、`:3163`（unpin）

```c
// virt/kvm/kvm_main.c:2851 hva_to_pfn_fast()
	if (kfp->pin)
		r = pin_user_pages_fast(kfp->hva, 1, FOLL_WRITE, &page) == 1;
	else
		r = get_user_page_fast_only(kfp->hva, FOLL_WRITE, &page);

// virt/kvm/kvm_main.c:2882 hva_to_pfn_slow()
	if (kfp->pin)
		npages = pin_user_pages_unlocked(kfp->hva, 1, &page, flags);
	else
		npages = get_user_pages_unlocked(kfp->hva, 1, &page, flags);
```

一句话：KVM 借用 Linux mm 的 GUP（Get User Pages）子系统，仅在 KVM 直接访问 guest 内存时 `pin`（防换出）；普通 EPT/NPT fault 只 `get`（不 pin），页面锁定语义完全依赖 host mm。

### 3) GPA→HPA 翻译（EPT/NPT）

- 函数名：`__kvm_faultin_pfn()`（GFN→PFN 入口）；EPT/NPT shadow MMU 初始化 `kvm_init_shadow_ept_mmu()` / `kvm_init_shadow_npt_mmu()`；SPTE 掩码 `kvm_mmu_set_ept_masks()`
- 源码位置：`virt/kvm/kvm_main.c:3049`；`arch/x86/kvm/mmu/mmu.c`（shadow ept/npt）；`arch/x86/kvm/mmu/spte.c`（ept masks）

```c
// virt/kvm/kvm_main.c:3049
kvm_pfn_t __kvm_faultin_pfn(const struct kvm_memory_slot *slot, gfn_t gfn,
			    unsigned int foll, bool *writable,
			    struct page **refcounted_page)
{
	struct kvm_follow_pfn kfp = {
		.slot = slot,
		.gfn = gfn,
		.flags = foll,
		.map_writable = writable,
		.refcounted_page = refcounted_page,
	};
	/* ... 解析 hva → kvm_follow_pfn() → hva_to_pfn() ... */
}
```

一句话：guest 二级页表缺页（EPT violation / NPF）时 arch fault handler 调用 `__kvm_faultin_pfn()` 把 GFN 解析成 host PFN，再由 VMX/SVM 侧写入 EPT/NPT 页表项完成 GPA→HPA 翻译；A/D 位与 execute-only 等硬件能力由 `kvm_mmu_set_ept_masks()` 配置到 SPTE。

### 4) 脏页追踪 [可选]

- 函数名：`kvm_get_dirty_log()`（取脏页位图）；`mark_page_dirty_in_slot()` / `mark_page_dirty()`（打脏标记）；另有 dirty ring（`virt/kvm/dirty_ring.c`）
- 源码位置：`virt/kvm/kvm_main.c:2158`（get_dirty_log）、`:3513`（mark_page_dirty_in_slot）

```c
// virt/kvm/kvm_main.c:3513
void mark_page_dirty_in_slot(struct kvm *kvm,
			     const struct kvm_memory_slot *memslot,
			     gfn_t gfn)
{
	if (memslot && kvm_slot_dirty_track_enabled(memslot)) {
		unsigned long rel_gfn = gfn - memslot->base_gfn;
		u32 slot = (memslot->as_id << 16) | memslot->id;
		if (kvm->dirty_ring_size && vcpu)
			kvm_dirty_ring_push(vcpu, slot, rel_gfn);
		else if (memslot->dirty_bitmap)
			set_bit_le(rel_gfn, memslot->dirty_bitmap);
	}
}
```

一句话：[可选] 用于 live migration，写 guest 页面时按 slot 打脏位（bitmap 或 dirty ring），用户态用 `KVM_GET_DIRTY_LOG` 取回增量脏页集合。

### 5) MMU 反向通知 [分歧]

- 函数名：`kvm_mmu_notifier_ops`（回调表）；注册 `mmu_notifier_register()`；核心回调 `kvm_mmu_notifier_invalidate_range_start()`
- 源码位置：`virt/kvm/kvm_main.c:878`（ops 表）、`:721`（invalidate_range_start）、`:889`（注册）

```c
// virt/kvm/kvm_main.c:878
static const struct mmu_notifier_ops kvm_mmu_notifier_ops = {
	.invalidate_range_start	= kvm_mmu_notifier_invalidate_range_start,
	.invalidate_range_end	= kvm_mmu_notifier_invalidate_range_end,
	.clear_flush_young	= kvm_mmu_notifier_clear_flush_young,
	.clear_young		= kvm_mmu_notifier_clear_young,
	.test_young		= kvm_mmu_notifier_test_young,
	.release		= kvm_mmu_notifier_release,
};
// :889  kvm->mmu_notifier.ops = &kvm_mmu_notifier_ops;
//       (mmu_notifier_register 挂到当前进程 mm)
```

一句话：[分歧] KVM 把回调注册进 host 进程 mm 的 mmu_notifier 链，当宿主页表因换出/COW/munmap 变动时同步 zap EPT/NPT——KVM 与 host mm 深度耦合，不 pin 全部 guest 内存；这是与 eager-pin 型 shim（如本项目 axvisor）最大的分歧点。

---

## 维度 2：vCPU

### 6) 硬件虚拟化启用（VMX/SVM）

- 函数名：`kvm_enable_virtualization()`（通用核心）；经 `cpuhp_setup_state()` 注册 `kvm_online_cpu` / `kvm_offline_cpu`；arch 侧 `kvm_arch_enable_virtualization()`（VMX 的 `hardware_enable` 执行 VMXON）
- 源码位置：`virt/kvm/kvm_main.c:5685`

```c
// virt/kvm/kvm_main.c:5685
static int kvm_enable_virtualization(void)
{
	int r;
	guard(mutex)(&kvm_usage_lock);
	if (kvm_usage_count++)
		return 0;
	kvm_arch_enable_virtualization();
	r = cpuhp_setup_state(CPUHP_AP_KVM_ONLINE, "kvm/cpu:online",
			      kvm_online_cpu, kvm_offline_cpu);
	if (r) goto err_cpuhp;
	register_syscore(&kvm_syscore);
	/* ... */
}
```

一句话：首个 VM 创建时引用计数从 0→1，通过 CPU 热插拔回调在每个在线 CPU 上执行 VMXON/EFER.SVME 打开硬件虚拟化扩展；CPU 上/下线由 Linux cpuhp 子系统驱动。

### 7) vCPU 创建 / 销毁

- 函数名：`kvm_vcpu_init()` / `kvm_vcpu_destroy()`；ioctl 入口 `kvm_vm_ioctl_create_vcpu()`；arch 侧 `kvm_arch_vcpu_create()`
- 源码位置：`virt/kvm/kvm_main.c:441`（init）、`:466`（destroy）、`:4151`（create ioctl）

```c
// virt/kvm/kvm_main.c:441
static void kvm_vcpu_init(struct kvm_vcpu *vcpu, struct kvm *kvm, unsigned id)
{
	mutex_init(&vcpu->mutex);
	vcpu->cpu = -1;
	vcpu->kvm = kvm;
	vcpu->vcpu_id = id;
	vcpu->pid = NULL;
	rcuwait_init(&vcpu->wait);
	kvm_async_pf_vcpu_init(vcpu);
	preempt_notifier_init(&vcpu->preempt_notifier, &kvm_preempt_ops);
	/* ... */
}
```

一句话：`KVM_CREATE_VCPU` ioctl 分配 vCPU 结构、初始化 mutex/等待队列/抢占通知器，`vcpu->cpu=-1` 表示尚未绑定物理 CPU；销毁时释放 pid 引用与 run 页。

### 8) vCPU 执行 VM entry

- 函数名：通用 `vcpu_enter_guest()`；VMX 侧 `vmx_vcpu_run()` → `vmx_vcpu_enter_exit()` → `__vmx_vcpu_run()`（汇编 VMLAUNCH/VMRESUME）
- 源码位置：`arch/x86/kvm/x86.c:11167`（vcpu_enter_guest）、`arch/x86/kvm/vmx/vmx.c:7515`（vmx_vcpu_run）、`:7476`（enter_exit）

```c
// arch/x86/kvm/vmx/vmx.c:7476
static noinstr void vmx_vcpu_enter_exit(struct kvm_vcpu *vcpu,
					unsigned int flags)
{
	struct vcpu_vmx *vmx = to_vmx(vcpu);
	guest_state_enter_irqoff();
	vmx_l1d_flush(vcpu);
	if (vcpu->arch.cr2 != native_read_cr2())
		native_write_cr2(vcpu->arch.cr2);
	vmx->fail = __vmx_vcpu_run(vmx, (unsigned long *)&vcpu->arch.regs, flags);
	vcpu->arch.cr2 = native_read_cr2();
	/* ... guest_state_exit_irqoff() */
}
```

一句话：进 guest 前 `guest_state_enter_irqoff()` 处理 RCU/lockdep/中断追踪，随后汇编例程执行 VMLAUNCH/VMRESUME 进入 guest；退出后回到 `vmx_handle_exit()`。

### 9) 寄存器读写

- 函数名：`__get_regs()` / `__set_regs()`，ioctl 入口 `kvm_arch_vcpu_ioctl_get_regs()` / `kvm_arch_vcpu_ioctl_set_regs()`；sregs 另有 `__get_sregs()`/`__set_sregs()`
- 源码位置：`arch/x86/kvm/x86.c:12134`（__get_regs）、`:12182`（__set_regs）、`:12170`/`:12215`（ioctl）

```c
// arch/x86/kvm/x86.c:12134
static void __get_regs(struct kvm_vcpu *vcpu, struct kvm_regs *regs)
{
	/* 若在指令模拟中途，先 writeback 模拟寄存器缓存 */
	regs->rax = kvm_rax_read(vcpu);
	regs->rbx = kvm_rbx_read(vcpu);
	/* ... rcx/rdx/rsi/rdi/rsp/rbp/r8..r15 ... */
	regs->rip = kvm_rip_read(vcpu);
	regs->rflags = kvm_get_rflags(vcpu);
}
// :12170 kvm_arch_vcpu_ioctl_get_regs: vcpu_load(); __get_regs(); vcpu_put();
```

一句话：`KVM_GET_REGS` / `KVM_SET_REGS` ioctl 在 `vcpu_load()/vcpu_put()` 保护下把 GPR+RIP+RFLAGS 在用户态与 vCPU 上下文间同步；这是 gvisor 每次 HLT 上下文切换依赖的路径。

### 10) CPUID 过滤

- 函数名：`kvm_emulate_cpuid()` → `kvm_cpuid()`；能力掩码 `kvm_cpu_cap_has()`/`kvm_cpu_cap_set()`；配置入口 `kvm_vcpu_ioctl_set_cpuid2()`
- 源码位置：`arch/x86/kvm/cpuid.c:2160`（emulate_cpuid）、`:2088`（kvm_cpuid）

```c
// arch/x86/kvm/cpuid.c:2160
int kvm_emulate_cpuid(struct kvm_vcpu *vcpu)
{
	u32 eax, ebx, ecx, edx;
	if (!is_smm(vcpu) && cpuid_fault_enabled(vcpu) &&
	    !kvm_require_cpl(vcpu, 0))
		return 1;
	eax = kvm_rax_read(vcpu);
	ecx = kvm_rcx_read(vcpu);
	kvm_cpuid(vcpu, &eax, &ebx, &ecx, &edx, false);
	kvm_rax_write(vcpu, eax); kvm_rbx_write(vcpu, ebx);
	kvm_rcx_write(vcpu, ecx); kvm_rdx_write(vcpu, edx);
	return kvm_skip_emulated_instruction(vcpu);
}
```

一句话：guest 执行 CPUID 触发 VM exit，KVM 从用户态预设的 CPUID2 表（经 KVM 能力掩码 sanitize）返回过滤后的特性——本项目曾靠清 leaf 0x1 ECX bit(24)(TSC_DEADLINE) 改变 guest 行为。

### 11) MSR 模拟

- 函数名：`kvm_emulate_rdmsr()` / `kvm_emulate_wrmsr()` → `__kvm_emulate_{rd,wr}msr()` → `kvm_get_msr()`/`kvm_set_msr()`
- 源码位置：`arch/x86/kvm/x86.c:2159`（rdmsr）、`:2195`（wrmsr）、`:2174`（__wrmsr 核心）

```c
// arch/x86/kvm/x86.c:2174
static int __kvm_emulate_wrmsr(struct kvm_vcpu *vcpu, u32 msr, u64 data)
{
	int r = kvm_emulate_msr_write(vcpu, msr, data);
	if (!r) {
		trace_kvm_msr_write(msr, data);
	} else {
		/* MSR 写失败 -> 询问用户空间 (KVM_EXIT_X86_WRMSR) */
		if (kvm_msr_user_space(vcpu, msr, KVM_EXIT_X86_WRMSR, data,
				       complete_fast_msr_access, r))
			return 0;
		if (r < 0) return r;
	}
	return kvm_x86_call(complete_emulated_msr)(vcpu, r);
}
```

一句话：guest RDMSR/WRMSR 触发 VM exit，KVM 按 MSR 分类透传/模拟/拒绝，未知 MSR 可上抛用户态 (`KVM_EXIT_X86_{RD,WR}MSR`)。

### 12) VM exit 分发 [分歧]

- 函数名：`vmx_handle_exit()` → `__vmx_handle_exit()`，按 `exit_reason.basic` 索引 `kvm_vmx_exit_handlers[]` 处理表；SVM 对应 `svm_handle_exit()`
- 源码位置：`arch/x86/kvm/vmx/vmx.c:6838`（vmx_handle_exit）、`:6682`（__vmx_handle_exit）

```c
// arch/x86/kvm/vmx/vmx.c:6682
static int __vmx_handle_exit(struct kvm_vcpu *vcpu, fastpath_t exit_fastpath)
{
	struct vcpu_vmx *vmx = to_vmx(vcpu);
	union vmx_exit_reason exit_reason = vmx_get_exit_reason(vcpu);
	u16 exit_handler_index;
	if (enable_pml && !is_guest_mode(vcpu))
		vmx_flush_pml_buffer(vcpu);
	/* ... 按 exit_reason.basic 走 kvm_vmx_exit_handlers[] 分发 ... */
}
```

一句话：[分歧] KVM 在内核态用一张 exit_reason→handler 的分发表处理绝大多数退出（EPT/CR/MSR/CPUID/HLT 等），仅无法内核处理的（如未知 MMIO/PIO、部分 MSR）才 `KVM_EXIT_*` 上抛用户态——与"薄内核+厚用户态"型 VMM 的分发边界不同。

---

## 维度 3：I/O

### 13) PIO/MMIO 拦截

- 函数名：`kvm_io_bus_write()` / `kvm_io_bus_read()` → `__kvm_io_bus_write()`（在注册的 `kvm_io_device` 上分发）；无匹配设备时上抛 `KVM_EXIT_MMIO`/`KVM_EXIT_IO`
- 源码位置：`virt/kvm/kvm_main.c:5880`（write）、`:5949`（read）

```c
// virt/kvm/kvm_main.c:5880
int kvm_io_bus_write(struct kvm_vcpu *vcpu, enum kvm_bus bus_idx, gpa_t addr,
		     int len, const void *val)
{
	struct kvm_io_bus *bus;
	struct kvm_io_range range = { .addr = addr, .len = len };
	bus = kvm_get_bus_srcu(vcpu->kvm, bus_idx);
	if (!bus) return -ENOMEM;
	return __kvm_io_bus_write(vcpu, bus, &range, val) < 0 ? -EOPNOTSUPP : 0;
}
```

一句话：guest PIO/MMIO 触发 VM exit 后，KVM 在内核 IO bus（KVM_MMIO_BUS/KVM_PIO_BUS）上查找匹配的内核态模拟设备（如 APIC/PIT/ioeventfd）；未命中的访问以 `KVM_EXIT_MMIO`/`KVM_EXIT_IO` 上抛用户态 QEMU 模拟。

### 14) I/O 事件通知（eventfd）

- 函数名：ioeventfd — `ioeventfd_write()`（挂到 IO bus，命中时 `eventfd_signal()`）；irqfd — `irqfd_wakeup()`（eventfd 就绪时注入中断）；配置 `kvm_ioeventfd()` / `kvm_irqfd()`
- 源码位置：`virt/kvm/eventfd.c:807`（ioeventfd_write）、`:202`（irqfd_wakeup）

```c
// virt/kvm/eventfd.c:807
ioeventfd_write(struct kvm_vcpu *vcpu, struct kvm_io_device *this, gpa_t addr,
		int len, const void *val)
{
	struct _ioeventfd *p = to_ioeventfd(this);
	if (!ioeventfd_in_range(p, addr, len, val))
		return -EOPNOTSUPP;
	eventfd_signal(p->eventfd);   /* 唤醒用户态 QEMU 的 I/O 线程 */
	return 0;
}
```

一句话：ioeventfd 让 guest 对特定 MMIO/PIO 地址的写"变成" eventfd 信号（VM exit 内核内直接消化，不必回用户态），irqfd 反向把用户态 eventfd 就绪转成 guest 中断注入——这是 virtio 快速路径的基石。

### 15) virtio 设备

- 函数名：未在参考树中找到（KVM 内核侧不实现）。
- 说明：virtio 设备（virtio-net/blk/console 等）的前后端协议、virtqueue 处理均在用户态 QEMU（或 vhost 内核模块，但那属独立子系统，不在本 KVM 参考树）实现。KVM 内核侧只提供上条的 ioeventfd/irqfd 加速通道供 virtio 使用。
- 一句话：KVM 内核侧不实现 virtio，由用户态 QEMU 承载（可选借助 vhost）。

### 16) 网络后端（TAP/TUN）

- 函数名：未在参考树中找到（KVM 内核侧不实现）。
- 说明：TAP/TUN、bridge、vhost-net 等网络后端在用户态 QEMU 与独立内核网络子系统实现，与 KVM 核心解耦。
- 一句话：KVM 内核侧不实现网络后端，由用户态 QEMU（+ host 网络栈）承载。

### 17) 块设备后端

- 函数名：未在参考树中找到（KVM 内核侧不实现）。
- 说明：块设备镜像（qcow2/raw）、AIO/io_uring 提交、缓存策略均在用户态 QEMU 实现。
- 一句话：KVM 内核侧不实现块设备后端，由用户态 QEMU 承载。

### 18) 设备模拟位置 [分歧]

- 函数名（内核内少数就地模拟）：LAPIC `arch/x86/kvm/lapic.c`、IOAPIC `arch/x86/kvm/ioapic.c`、PIT `arch/x86/kvm/i8254.c`、PIC `arch/x86/kvm/i8259.c`、coalesced MMIO `virt/kvm/coalesced_mmio.c`
- 一句话：[分歧] KVM 把对延迟敏感的中断/定时器控制器（LAPIC/IOAPIC/PIT/PIC）放在内核内就地模拟以减少 VM exit 往返，其余绝大多数设备（磁盘/网卡/串口/PCI）在用户态 QEMU 模拟——这是"内核态最小设备集 + 用户态完整设备模型"的分工，与全内核态或全用户态方案都不同。

---

## 维度 4：中断

### 19) LAPIC 模拟

- 函数名：中断接受 `__apic_accept_irq()`；寄存器写 `kvm_lapic_reg_write()`；查 pending `kvm_apic_has_interrupt()`；LVT 本地投递 `kvm_apic_local_deliver()`
- 源码位置：`arch/x86/kvm/lapic.c:1398`（__apic_accept_irq）、`:2407`（reg_write）

```c
// arch/x86/kvm/lapic.c:1398
static int __apic_accept_irq(struct kvm_lapic *apic, int delivery_mode,
			     int vector, int level, int trig_mode,
			     struct rtc_status *rtc_status)
{
	struct kvm_vcpu *vcpu = apic->vcpu;
	switch (delivery_mode) {
	case APIC_DM_FIXED:
		if (!apic_enabled(apic)) break;
		result = 1;
		/* 设置 TMR、调 arch deliver_interrupt 置 IRR，并 kick vCPU */
		kvm_x86_call(deliver_interrupt)(apic, delivery_mode,
						trig_mode, vector);
		break;
	/* APIC_DM_NMI / INIT / SIPI ... */
	}
}
```

一句话：KVM 在内核内完整模拟 local APIC（IRR/ISR/TMR/LVT/ICR/timer），`__apic_accept_irq()` 是所有中断进入某 vCPU LAPIC 的汇聚点，置 IRR 并 kick 目标 vCPU。

### 20) IOAPIC 模拟

- 函数名：`kvm_ioapic_set_irq()` → `ioapic_service()`；MMIO `ioapic_mmio_write()`/`ioapic_mmio_read()`
- 源码位置：`arch/x86/kvm/ioapic.c:500`（set_irq）、`:457`（service）、`:653`（mmio_write）

```c
// arch/x86/kvm/ioapic.c:500
int kvm_ioapic_set_irq(struct kvm_kernel_irq_routing_entry *e, struct kvm *kvm,
		       int irq_source_id, int level, bool line_status)
{
	struct kvm_ioapic *ioapic = kvm->arch.vioapic;
	int irq = e->irqchip.pin;
	spin_lock(&ioapic->lock);
	irq_level = __kvm_irq_line_state(&ioapic->irq_states[irq],
					 irq_source_id, level);
	ret = ioapic_service(ioapic, irq, line_status);
	spin_unlock(&ioapic->lock);
	return ret;
}
```

一句话：KVM 内核内模拟 IOAPIC（24 个重定向表项），把设备 GSI 电平/边沿信号按重定向项翻译成对目标 LAPIC 的中断投递。

### 21) 中断注入

- 函数名：排队 `kvm_queue_interrupt()`（inline，置 `vcpu->arch.interrupt`）；NMI `kvm_inject_nmi()`；实际注入在 `inject_pending_event()`/`kvm_x86_ops->inject_irq`，VM entry 前完成
- 源码位置：`arch/x86/kvm/x86.h:222`（kvm_queue_interrupt）、`arch/x86/kvm/x86.c:1012`（inject_nmi）

```c
// arch/x86/kvm/x86.h:222
static inline void kvm_queue_interrupt(struct kvm_vcpu *vcpu, u8 vector, bool soft)
{
	vcpu->arch.interrupt.injected = true;
	vcpu->arch.interrupt.soft = soft;
	vcpu->arch.interrupt.nr = vector;
}
// arch/x86/kvm/x86.c:1012
void kvm_inject_nmi(struct kvm_vcpu *vcpu)
{
	atomic_inc(&vcpu->arch.nmi_queued);
	kvm_make_request(KVM_REQ_NMI, vcpu);
}
```

一句话：KVM 先把待注入中断/NMI/异常记入 vcpu->arch 状态，下一次 `vcpu_enter_guest()` 前由 arch 侧写入 VMCS/VMCB 的 VM-entry 事件字段，硬件在进 guest 时投递。

### 22) 中断通知路径 [分歧]

- 函数名：路由入口 `kvm_set_irq()`（`virt/kvm/irqchip.c:70`）；irqfd 快速原子注入 `kvm_arch_set_irq_inatomic()`；kick `__kvm_vcpu_kick()`；硬件加速为 posted-interrupt（`vmx_deliver_posted_interrupt`）
- 源码位置：`virt/kvm/irqchip.c:70`、`virt/kvm/eventfd.c:189`（kvm_arch_set_irq_inatomic weak）

一句话：[分歧] KVM 的中断通知有多条路径——软件路径经 irq routing 表 `kvm_set_irq()`→LAPIC/IOAPIC→`kvm_vcpu_kick()` 发 IPI 逼 vCPU 退出并在下次 entry 注入；硬件加速路径用 VT-d posted-interrupt 直接投递到运行中的 vCPU 而不 VM exit。本项目 shim 曾因 ACK_INTR_ON_EXIT 吞掉 host 外部中断而缺失 KVM 式 `handle_external_interrupt_irqoff()` 的 re-dispatch，这是与 KVM 的关键分歧。

---

## 维度 5：时钟

### 23) TSC 虚拟化

- 函数名：读 guest TSC `kvm_read_l1_tsc()`；缩放 `kvm_scale_tsc()`；算 offset `kvm_compute_l1_tsc_offset()`；写入 VMCS 由 `kvm_x86_ops->write_tsc_offset`
- 源码位置：`arch/x86/kvm/x86.c:2678`（read_l1_tsc）、`:2659`（scale_tsc）、`:2669`（compute offset）

```c
// arch/x86/kvm/x86.c:2678
u64 kvm_read_l1_tsc(struct kvm_vcpu *vcpu, u64 host_tsc)
{
	return vcpu->arch.l1_tsc_offset +
		kvm_scale_tsc(host_tsc, vcpu->arch.l1_tsc_scaling_ratio);
}
```

一句话：guest 看到的 TSC = host TSC 经缩放比例调整后加 per-vCPU offset，KVM 用硬件 TSC scaling/offset 字段实现，使 guest TSC 在迁移/暂停后保持单调一致。

### 24) 高精度定时器源（hrtimer）

- 函数名：`hrtimer_start()` / `hrtimer_cancel()` / `hrtimer_setup()`（Linux hrtimer 子系统），KVM 在 LAPIC/PIT 定时器中使用
- 源码位置：`arch/x86/kvm/lapic.c:2089`（start）、`:1872`（cancel）；PIT 在 `arch/x86/kvm/i8254.c`

```c
// arch/x86/kvm/lapic.c:2089 (start_sw_tscdeadline 内)
	if (likely(tscdeadline > guest_tsc) &&
	    likely(ns > apic->lapic_timer.timer_advance_ns)) {
		expire = ktime_add_ns(now, ns);
		expire = ktime_sub_ns(expire, ktimer->timer_advance_ns);
		hrtimer_start(&ktimer->timer, expire, HRTIMER_MODE_ABS_HARD);
	} else
		apic_timer_expired(apic, false);
```

一句话：KVM 复用 Linux 高精度定时器（`HRTIMER_MODE_ABS_HARD`，硬中断上下文回调）作为软件模拟 guest 定时器到期的时间源——本项目 shim 因缺等价的可靠 hard-IRQ timer pump 曾出现 timer drain 停摆。

### 25) 定时器设备模拟（LAPIC timer）

- 函数名：硬件加速 `start_hv_timer()`（VMX preemption timer）；软件回退 `start_sw_timer()` → `start_sw_period()`/`start_sw_tscdeadline()`；到期 `apic_timer_expired()`；调度 `restart_apic_timer()`
- 源码位置：`arch/x86/kvm/lapic.c:2251`（hv）、`:2293`（sw）、`:2063`（tscdeadline）

```c
// arch/x86/kvm/lapic.c:2293
static void start_sw_timer(struct kvm_lapic *apic)
{
	struct kvm_timer *ktimer = &apic->lapic_timer;
	if (apic->lapic_timer.hv_timer_in_use)
		cancel_hv_timer(apic);
	if (apic_lvtt_period(apic) || apic_lvtt_oneshot(apic))
		start_sw_period(apic);
	else if (apic_lvtt_tscdeadline(apic))
		start_sw_tscdeadline(apic);
}
// restart_apic_timer(): if (!start_hv_timer(apic)) start_sw_timer(apic);
```

一句话：KVM 模拟 LAPIC timer 的三种模式（periodic/oneshot/TSC-deadline），优先用 VMX preemption timer 硬件加速，不可用时回退 hrtimer；本项目曾坐实 guest 使用 TSC-deadline 模式而 shim 未虚拟化 MSR 0x6E0 导致定时器不投递。

### 26) 单调时间获取

- 函数名：`ktime_get()`（单调）、`ktime_get_boottime_ns()`、`get_kvmclock_ns()`（pvclock）、`rdtsc()`
- 源码位置：`arch/x86/kvm/lapic.c:2079`（ktime_get 用例）、`arch/x86/kvm/x86.c:2407`（boottime）、`:3258`（get_kvmclock_ns）

```c
// arch/x86/kvm/x86.c:3258
u64 get_kvmclock_ns(struct kvm *kvm)
{
	struct kvm_clock_data data;
	get_kvmclock(kvm, &data);
	return data.clock;
}
```

一句话：KVM 用 Linux 单调时钟 `ktime_get()` 做定时器到期与 halt-polling 计时，用 `get_kvmclock_ns()`（基于 TSC + host 时钟）为 guest 提供 pvclock；本项目曾撤销 kvm-clock CPUID 广告让 guest 回退原生时钟源。

---

## 维度 6：调度同步

### 27) 每 vCPU 一线程

- 函数名：`KVM_RUN` ioctl 处理（`kvm_vcpu_ioctl` 内 `case KVM_RUN`）→ `kvm_arch_vcpu_ioctl_run()`；`vcpu->pid` 绑定调用线程；`kvm_arch_vcpu_run_pid_change()`
- 源码位置：`virt/kvm/kvm_main.c:4440`（KVM_RUN）、`:447`（vcpu->pid 初始化）

```c
// virt/kvm/kvm_main.c:4440
	case KVM_RUN: {
		struct pid *oldpid = vcpu->pid;
		if (unlikely(oldpid != task_pid(current))) {
			/* 运行此 vCPU 的线程变了 */
			r = kvm_arch_vcpu_run_pid_change(vcpu);
			if (r) break;
			newpid = get_task_pid(current, PIDTYPE_PID);
			/* ... 更新 vcpu->pid ... */
		}
		r = kvm_arch_vcpu_ioctl_run(vcpu);
	}
```

一句话：KVM 不自建线程——每个 vCPU 由用户态一个普通线程反复 `ioctl(KVM_RUN)` 驱动，`vcpu->pid` 记录该线程，由 Linux CFS 统一调度；这是"1 vCPU = 1 host task"模型，本项目 shim 亦对齐此模型。

### 28) CPU 亲和性

- 函数名：KVM 本身不设置亲和性；仅在 `vcpu_load()` 里用 `get_cpu()` 记录当前物理 CPU 到 `vcpu->cpu`，供 kick 发 IPI 用；`kvm_arch_vcpu_load()`
- 源码位置：`virt/kvm/kvm_main.c:164`（vcpu_load 记录 cpu）、`:238`/`:3837`（读 vcpu->cpu 决定 IPI 目标）

```c
// virt/kvm/kvm_main.c:164
void vcpu_load(struct kvm_vcpu *vcpu)
{
	int cpu = get_cpu();
	__this_cpu_write(kvm_running_vcpu, vcpu);
	preempt_notifier_register(&vcpu->preempt_notifier);
	kvm_arch_vcpu_load(vcpu, cpu);   /* 内部记录 vcpu->cpu = cpu */
	put_cpu();
}
```

一句话：KVM 不强制 vCPU 绑核，亲和性完全交给 host 调度器/用户态（`taskset`/`sched_setaffinity`）；KVM 只被动记录 vCPU 当前所在物理 CPU 以便发送 kick IPI。

### 29) vCPU 休眠 / 唤醒（halt/kick）

- 函数名：休眠 `kvm_vcpu_halt()`（含 halt-polling）→ `kvm_vcpu_block()` → `schedule()`；条件检查 `kvm_vcpu_check_block()`；唤醒 `kvm_vcpu_wake_up()`；踢出 `__kvm_vcpu_kick()`
- 源码位置：`virt/kvm/kvm_main.c:3720`（halt）、`:3642`（block）、`:3793`（wake_up）、`:3809`（kick）

```c
// virt/kvm/kvm_main.c:3720 kvm_vcpu_halt() —— 先自适应 poll 再睡
	if (do_halt_poll) {
		do {
			if (kvm_vcpu_check_block(vcpu) < 0) goto out;
			cpu_relax();
		} while (kvm_vcpu_can_poll(cur, stop));
	}
	waited = kvm_vcpu_block(vcpu);   /* 无事件则 schedule() 真睡 */

// virt/kvm/kvm_main.c:3809 __kvm_vcpu_kick() —— 唤醒或发 IPI 逼退 guest
	if (kvm_vcpu_wake_up(vcpu)) return;
	if (kvm_arch_vcpu_should_kick(vcpu))
		smp_send_reschedule(cpu);   /* 或 smp_call_function_single */
```

一句话：guest HLT 时 vCPU 线程先忙等 halt-poll（低延迟）再 `schedule()` 让核，中断到来时 `kvm_vcpu_wake_up()` 唤醒或 `__kvm_vcpu_kick()` 发 reschedule IPI 逼 vCPU 退出 guest——本项目超订死锁多次围绕此 halt/kick/wake 链。

### 30) 事件循环

- 函数名：`kvm_arch_vcpu_ioctl_run()` → `vcpu_run()`（`arch/x86/kvm/x86.c`）循环调用 `vcpu_enter_guest()`；上抛用户态时返回，用户态 QEMU 处理后再次 `KVM_RUN`
- 源码位置：`arch/x86/kvm/x86.c:11765`（vcpu_run 内 `vcpu_enter_guest()` 循环）

```c
// arch/x86/kvm/x86.c (vcpu_run 主循环，节选)
	for (;;) {
		if (kvm_vcpu_running(vcpu))
			r = vcpu_enter_guest(vcpu);   /* :11765 */
		else
			r = vcpu_block(vcpu);
		if (r <= 0) break;   /* r<=0 -> 返回用户态处理 KVM_EXIT_* */
		/* ... 处理 pending request / 信号 / need_resched ... */
	}
```

一句话：KVM 内核内有一个 per-vCPU 运行循环（进 guest → 处理内核可消化的 exit → 再进 guest），只有内核处理不了的事件才返回用户态；真正的"设备事件循环"（select/poll 各 fd）在用户态 QEMU 的 I/O 线程。

### 31) 锁原语

- 函数名：`spinlock_t mmu_lock`（保护 EPT/影子页表）、`struct mutex slots_lock`（memslot 变更）、`struct mutex lock`（VM 级）、`struct mutex irq_lock`、`struct srcu_struct srcu`（memslot 无锁读）
- 源码位置：`include/linux/kvm_host.h:774`（mmu_lock）、`:777`（slots_lock）、`:820`（lock）、`:841`（irq_lock）、`:861`（srcu）

```c
// include/linux/kvm_host.h (struct kvm 内)
	spinlock_t mmu_lock;                 // :774
	struct mutex slots_lock;             // :777
	spinlock_t mn_invalidate_lock;       // :801
	struct mutex lock;                   // :820
	struct mutex irq_lock;               // :841
	struct srcu_struct srcu;             // :861
```

一句话：KVM 直接复用 Linux 锁原语——spinlock 用于不可睡眠短临界区（页表），mutex 用于可睡眠配置路径（memslot/中断路由），SRCU 让 memslot 读者无阻塞；锁层次为 `lock → slots_lock → irq_lock`。

### 32) 抢占通知 [可选]

- 函数名：`preempt_notifier`（vcpu 结构成员）+ `kvm_preempt_ops`（`kvm_sched_in`/`kvm_sched_out`）；注册/注销在 `vcpu_load()`/`vcpu_put()`
- 源码位置：`virt/kvm/kvm_main.c:115`（kvm_preempt_ops）、`:169`（register）、`:181`（unregister）、`:458`（init）

```c
// virt/kvm/kvm_main.c:169 (vcpu_load)
	preempt_notifier_register(&vcpu->preempt_notifier);
// :181 (vcpu_put)
	preempt_notifier_unregister(&vcpu->preempt_notifier);
// :458 (kvm_vcpu_init)
	preempt_notifier_init(&vcpu->preempt_notifier, &kvm_preempt_ops);
```

一句话：[可选] KVM 注册抢占通知器，当 vCPU 线程被 CFS 换出/换入时收到 `kvm_sched_out`/`kvm_sched_in` 回调，从而保存/恢复与物理 CPU 绑定的 guest 状态（如 VMCS、user-return MSR）——依赖 Linux 调度器的抢占通知机制。

---

## 维度 7：安全

### 33) 权限检查

- 函数名：KVM 内核侧无专门的 capability 检查（`grep capable()` 在 `kvm_main.c` 无命中）；访问控制通过 `/dev/kvm` 的文件权限 + anon-inode fd（`anon_inode_getfd`/`anon_inode_getfile`）实现；VM/vCPU fd 带 `O_CLOEXEC`
- 源码位置：`virt/kvm/kvm_main.c:5498`（kvm-vm fd）、`:4114`（vcpu fd）、`:5479`（create_vm）

```c
// virt/kvm/kvm_main.c:5479
static int kvm_dev_ioctl_create_vm(unsigned long type)
{
	int fd = get_unused_fd_flags(O_CLOEXEC);
	kvm = kvm_create_vm(type, fdname);
	file = anon_inode_getfile("kvm-vm", &kvm_vm_fops, kvm, O_RDWR);
	/* 返回一个匿名 inode fd 作为 VM 句柄 */
}
```

一句话：KVM 的权限模型很薄——谁能 `open("/dev/kvm")`（由文件系统 DAC/LSM 决定）谁就能建 VM，之后靠 anon-inode fd 隔离 VM/vCPU 句柄；细粒度沙箱不在 KVM 内核层。

### 34) 进程沙箱

- 函数名：未在参考树中找到（KVM 内核侧不实现）。KVM 只把 VM 绑定到创建它的 host 进程 mm（`mmgrab(current->mm)`），guest 运行在该进程地址空间内。
- 源码位置：`virt/kvm/kvm_main.c:1108`（mmgrab）

```c
// virt/kvm/kvm_main.c:1108
	mmgrab(current->mm);
	kvm->mm = current->mm;
```

一句话：进程沙箱（seccomp-bpf、namespace、cgroup、Landlock）由用户态 QEMU/VMM 自行配置；KVM 内核侧只保证 guest 内存不越出宿主进程地址空间，沙箱本身由用户态承载。

### 35) 资源限制

- 函数名：KVM 内核侧无独立资源配额逻辑；内存受 host mm 常规机制约束（GUP pin 计入 `RLIMIT_MEMLOCK`/`account_locked_vm`，属 mm 子系统）；vCPU 数受 `KVM_MAX_VCPUS` 编译期上限
- 源码位置：GUP pin 语义见 `virt/kvm/kvm_main.c:2867`/`:2901`（`pin_user_pages_*`，计入 mm 锁页配额）；`kvm->mm = current->mm`（`:1109`）使 guest 内存计入宿主进程

一句话：KVM 不自建 CPU/内存配额，完全复用 Linux 的 cgroup（CPU/memory）、`RLIMIT_MEMLOCK`（pin 页）与进程级 mm 计费；资源限制策略由用户态 + host cgroup 承载。

### 36) 设备访问控制

- 函数名：VFIO 设备直通 `kvm_vfio_ops`（`kvm_vfio_create`/`kvm_vfio_set_file`/`kvm_vfio_set_attr`）；一致性检查 `kvm_vfio_file_enforced_coherent()`；IOMMU 组 `kvm_vfio_file_iommu_group()`；创建入口 `KVM_CREATE_DEVICE`
- 源码位置：`virt/kvm/vfio.c:347`（kvm_vfio_ops）、`:266`（set_file）、`:84`（iommu_group）

```c
// virt/kvm/vfio.c:347
static const struct kvm_device_ops kvm_vfio_ops = {
	.name    = "kvm-vfio",
	.create  = kvm_vfio_create,
	.set_attr = kvm_vfio_set_attr,
	/* ... */
};
```

一句话：物理设备直通的访问控制通过 VFIO 框架完成——用户态先用 VFIO/IOMMU 把设备与 IOMMU group 绑定，再经 `KVM_CREATE_DEVICE`(kvm-vfio) 关联到 VM，KVM 校验 DMA 一致性；具体 IOMMU 隔离由 Linux VFIO 子系统承载。

---

## 统计

按 36 个接口在本 KVM 内核参考树 `code/kvm-linux-reference/` 中的抽取结果：

- 在内核树找到真实代码：**31** 项
  - 维度1：1-5（全部 5 项）
  - 维度2：6-12（全部 7 项）
  - 维度3：13、14、18（3 项，其中 18 为内核内最小设备集）
  - 维度4：19-22（全部 4 项）
  - 维度5：23-26（全部 4 项）
  - 维度6：27-32（全部 6 项）
  - 维度7：33、36（2 项：/dev/kvm+anon-inode fd 权限、VFIO 设备控制）
- 明确标注"KVM 内核侧不实现，由用户态 QEMU 承载"：**5** 项
  - 维度3：15（virtio）、16（网络后端 TAP/TUN）、17（块设备后端）
  - 维度7：34（进程沙箱，仅 `mmgrab` 绑定 mm）、35（资源限制，复用 cgroup/RLIMIT，无独立配额逻辑）
- 未在参考树中找到（编造为 0）：**0** 项

分歧/可选标注：
- [分歧]：5（MMU 反向通知，与 eager-pin shim 分歧）、12（VM exit 分发边界）、18（设备模拟位置）、22（中断通知路径，含 ACK_INTR_ON_EXIT re-dispatch）——均已抽取并标注。
- [可选]：4（脏页追踪）、32（抢占通知）——均已抽取并标注。

说明：本项目 axvisor shim 的多处历史根因（eager-pin vs MMU-notifier、TSC-deadline MSR 0x6E0 未虚拟化、ACK_INTR_ON_EXIT 吞中断、halt/kick/wake 超订死锁、timer drain 停摆）在上述对应接口条目中均可对照到 KVM 的真实实现路径。
