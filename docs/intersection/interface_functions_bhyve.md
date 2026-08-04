# bhyve / FreeBSD 侧接口函数抽取

> 本文档对 36 个 "hypervisor ↔ OS 接口" 逐个给出 bhyve/FreeBSD 侧的真实函数名、源码位置(相对 `code/bhyve-reference/`)与核心源码片段。
> bhyve 分两层:内核态 vmm.ko(`sys/amd64/vmm/`)与用户态 bhyve(8)(`usr.sbin/bhyve/`),两者经 libvmmapi(`lib/libvmmapi/`)+ `/dev/vmm` ioctl 通信。
> 所有片段均从参考源码树 grep/read 得出。找不到者标注"未在参考树中找到"。

---

## 维度 1: 内存管理

### 1) Guest 内存分配与映射

**内核态 `vm_alloc_memseg()` + `vm_mmap_memseg()`** — `sys/amd64/vmm/vmm.c:809`, `:877`

`vm_alloc_memseg` 用 FreeBSD VM 对象分配器创建 guest 内存段(swap-backed VM object);`vm_mmap_memseg` 把段映射进 VM 的 vmspace(EPT/NPT 地址空间)。

```c
// vmm.c:809
int
vm_alloc_memseg(struct vm *vm, int ident, size_t len, bool sysmem)
{
	struct mem_seg *seg;
	vm_object_t obj;
	...
	obj = vm_object_allocate(OBJT_SWAP, len >> PAGE_SHIFT);
	if (obj == NULL)
		return (ENOMEM);
	seg->len = len;
	seg->object = obj;
	seg->sysmem = sysmem;
	return (0);
}
```

```c
// vmm.c:917 (vm_mmap_memseg 内)
	error = vm_map_find(&vm->vmspace->vm_map, seg->object, first, &gpa,
	    len, 0, VMFS_NO_SPACE, prot, prot, 0);   // 把段插入 guest 地址空间
	...
	vm_object_reference(seg->object);
```

对应"guest 物理内存段分配 + 映射进二级地址空间"。

**用户态 `vm_setup_memory()` / `setup_memory_segment()`** — `lib/libvmmapi/vmmapi.c:399`, `:422`

bhyve(8) 先 `VM_ALLOC_MEMSEG` 分配段,再经 `VM_MMAP_MEMSEG` ioctl 把段映射进内核 VM,并用 `mmap()` 把同一段映射进 bhyve 进程用户空间(设备模拟通过它读写 guest RAM)。

```c
// vmmapi.c:399
static int
setup_memory_segment(struct vmctx *ctx, vm_paddr_t gpa, size_t len, char *base)
{
	char *ptr;
	int error, flags;

	/* Map 'len' bytes starting at 'gpa' in the guest address space */
	error = vm_mmap_memseg(ctx, gpa, VM_SYSMEM, gpa, len, PROT_ALL);
	if (error)
		return (error);
	flags = MAP_SHARED | MAP_FIXED;
	...
	/* mmap into the process address space on the host */
	ptr = mmap(base + gpa, len, PROT_RW, flags, ctx->fd, gpa);
```

对应用户态"把 guest RAM 双重映射(内核 VM + 进程地址空间)"。

### 2) 页面锁定 / 防换出

**内核态 `vm_map_wire()`(经 `VM_MEMMAP_F_WIRED`)+ `vm_page_wired()`** — `sys/amd64/vmm/vmm.c:924`, `:1075`

映射段时若带 `VM_MEMMAP_F_WIRED` 标志,调 `vm_map_wire` 把 guest 页面 wired 在物理内存中防止被 page daemon 换出;IOMMU 直通路径用 `vm_page_wired()` 断言页面确已 wired。

```c
// vmm.c:924
	if (flags & VM_MEMMAP_F_WIRED) {
		error = vm_map_wire(&vm->vmspace->vm_map, gpa, gpa + len,
		    VM_MAP_WIRE_USER | VM_MAP_WIRE_NOHOLES);
		if (error != KERN_SUCCESS) {
			vm_map_remove(&vm->vmspace->vm_map, gpa, gpa + len);
			return (error == KERN_RESOURCE_SHORTAGE ? ENOMEM : EFAULT);
		}
	}
```

```c
// vmm.c:1075 (vm_iommu_map 内)
		KASSERT(vm_page_wired(PHYS_TO_VM_PAGE(hpa)),
		    ("vm_iommu_map: vm %p gpa %jx hpa %jx not wired", ...));
```

对应 KVM 的 `pin_user_pages_fast()`(防 guest 内存被换出)。运行期临时按页 hold 用 `vm_fault_quick_hold_pages()`(`vmm.c:1175`,`_vm_gpa_hold` 内)。

### 3) GPA→HPA 翻译(EPT/NPT)

**内核态 `pmap_extract()` + EPT 专用 pmap `ept_pinit()`/`ept_vmspace_alloc()`** — `sys/amd64/vmm/vmm.c:1061`, `sys/amd64/vmm/intel/ept.c:173`

bhyve 不自建影子页表:guest 的 vmspace 用一个 `PT_EPT` 类型的 pmap,由 FreeBSD pmap 子系统直接充当 EPT 页表。`pmap_extract()` 走这个 pmap 把 GPA 翻成 HPA。

```c
// ept.c:173
static int
ept_pinit(pmap_t pmap)
{
	return (pmap_pinit_type(pmap, PT_EPT, ept_pmap_flags));
}

struct vmspace *
ept_vmspace_alloc(vm_offset_t min, vm_offset_t max)
{
	return (vmspace_alloc(min, max, ept_pinit));
}
```

```c
// vmm.c:1061 (vm_iommu_map: 直通设备的 GPA→HPA)
		hpa = pmap_extract(vmspace_pmap(vm->vmspace), gpa);
```

AMD 侧对应 `npt.c` 的 `npt_pinit()`(`PT_RVI`)。对应"二级地址翻译"。EPTP 生成见 `ept.c:194 eptp()`。

### 4) 脏页追踪 [可选]

**未在参考树中找到独立的脏页位图接口**。`sys/amd64/vmm/` 中无 dirty-bitmap/`VM_GET_DIRTY_LOG` 类接口(grep `dirty`/`bitmap` 只命中 FPU dirty 与 `pmap_emulate_accessed_dirty`)。相关的 A/D 位仅在 EPT violation 模拟路径出现:

```c
// vmm.c:1720 (vm_handle_paging: 模拟 accessed/dirty 位)
		rv = pmap_emulate_accessed_dirty(vmspace_pmap(vm->vmspace),
		    vme->u.paging.gpa, ftype);
```

bhyve 无 KVM 式的 live-migration 脏页日志(快照走 `VM_SNAPSHOT_REQ` 全量 dump,见维度 6)。

### 5) MMU 反向通知 [分歧]

**未在参考树中找到 MMU notifier 机制**(grep `mmu_notifier`/`invalidate_range` 在 `sys/amd64/vmm/` 无命中)。这是设计分歧点:bhyve 的 guest 内存全部 wired + 由 FreeBSD VM object/pmap 统一管理,不需要类似 Linux `mmu_notifier` 的反向失效回调;EPT 页表就是 host pmap,pmap 自身的失效路径(`pmap_invalidate_*` / `smp_rendezvous` 的 `invept`)天然覆盖,无需额外注册通知。EPT TLB 失效见 `ept.c:170 smp_rendezvous(..., invept_single_context, ...)`。

---

## 维度 2: vCPU 管理

### 6) 硬件虚拟化启用(VMX / SVM)

**内核态 `vmx_enable()`/`vmx_modinit()`(Intel)与 `svm_enable()`/`svm_modinit()`(AMD)** — `sys/amd64/vmm/intel/vmx.c:628`, `sys/amd64/vmm/amd/svm.c:209`

`vmx_enable` 置 `CR4.VMXE` 并执行 `vmxon` 进入 VMX root 模式;`svm_enable` 置 `EFER.SVM` 并设 `MSR_VM_HSAVE_PA`。二者都由 `*_modinit` 经 `smp_rendezvous` 在所有 CPU 上执行。

```c
// vmx.c:628
static void
vmx_enable(void *arg __unused)
{
	int error;
	uint64_t feature_control;

	feature_control = rdmsr(MSR_IA32_FEATURE_CONTROL);
	...
	load_cr4(rcr4() | CR4_VMXE);
	*(uint32_t *)&vmxon_region[curcpu * PAGE_SIZE] = vmx_revision();
	error = vmxon(&vmxon_region[curcpu * PAGE_SIZE]);
	if (error == 0)
		vmxon_enabled[curcpu] = 1;
}
```

```c
// svm.c:209
static void
svm_enable(void *arg __unused)
{
	uint64_t efer;
	efer = rdmsr(MSR_EFER);
	efer |= EFER_SVM;
	wrmsr(MSR_EFER, efer);
	wrmsr(MSR_VM_HSAVE_PA, vtophys(&hsave[curcpu * PAGE_SIZE]));
}
```

对应"打开 CPU 硬件虚拟化扩展"。

### 7) vCPU 创建 / 销毁

**内核态 `vcpu_alloc()` + `vcpu_init()` / `vcpu_cleanup()`** — `sys/amd64/vmm/vmm.c:342`, `:362`, `:328`

`vcpu_alloc` 分配 `struct vcpu` 并初始化锁/FPU 保存区/stats;`vcpu_init` 经 backend ops `vmmops_vcpu_init` 建后端(VMCS/VMCB)状态与 vlapic;`vcpu_cleanup` 反向释放。

```c
// vmm.c:342
vcpu_alloc(struct vm *vm, int vcpu_id)
{
	struct vcpu *vcpu;
	...
	vcpu = malloc(sizeof(*vcpu), M_VM, M_WAITOK | M_ZERO);
	vcpu_lock_init(vcpu);
	vcpu->state = VCPU_IDLE;
	vcpu->hostcpu = NOCPU;
	vcpu->vcpuid = vcpu_id;
	vcpu->guestfpu = fpu_save_area_alloc();
	vcpu->stats = vmm_stat_alloc();
	return (vcpu);
}
// vmm.c:362
static void
vcpu_init(struct vcpu *vcpu)
{
	vcpu->cookie = vmmops_vcpu_init(vcpu->vm->cookie, vcpu, vcpu->vcpuid);
	vcpu->vlapic = vmmops_vlapic_init(vcpu->cookie);
	...
}
```

用户态经 `VM_ACTIVATE_CPU` ioctl 激活。对应 `KVM_CREATE_VCPU`。

### 8) vCPU 执行(VM_RUN)

**内核态 `vm_run()` → backend `vmx_run()`/`svm_vmrun()`;用户态 `VM_RUN` ioctl** — `sys/amd64/vmm/vmm.c:2012`, `sys/amd64/vmm/intel/vmx.c:3027`

`vm_run` 保存/恢复 FPU,置 vCPU 状态为 RUNNING,经 `vmmops_run` 进入 guest(VMLAUNCH/VMRESUME 或 VMRUN),返回后处理 exit。用户态每 vCPU 线程循环发 `VM_RUN` ioctl。

```c
// vmm.c:2012
vm_run(struct vcpu *vcpu)
{
	...
	pmap = vmspace_pmap(vm->vmspace);
	...
	restore_guest_fpustate(vcpu);
	vcpu_require_state(vcpu, VCPU_RUNNING);
	error = vmmops_run(vcpu->cookie, vcpu->nextrip, pmap, &evinfo);
	vcpu_require_state(vcpu, VCPU_FROZEN);
	save_guest_fpustate(vcpu);
	vmm_stat_incr(vcpu, VCPU_TOTAL_RUNTIME, rdtsc() - tscval);
```

后端入口 `vmx_run()`(`vmx.c:3027`),ops 表 `vmx.c:4274 .run = vmx_run`。对应 `KVM_RUN`。

### 9) 寄存器读写

**内核态 `vm_get_register()` / `vm_set_register()`;用户态 `VM_GET_REGISTER`/`VM_SET_REGISTER` ioctl** — `sys/amd64/vmm/vmm.c:1223`, `:1233`

薄封装,校验 reg id 后转 backend `vmmops_getreg`/`vmmops_setreg`;写 RIP 时会同步 `nextrip`。

```c
// vmm.c:1223
int
vm_get_register(struct vcpu *vcpu, int reg, uint64_t *retval)
{
	if (reg >= VM_REG_LAST)
		return (EINVAL);
	return (vmmops_getreg(vcpu->cookie, reg, retval));
}

int
vm_set_register(struct vcpu *vcpu, int reg, uint64_t val)
{
	...
	error = vmmops_setreg(vcpu->cookie, reg, val);
	if (error || reg != VM_REG_GUEST_RIP)
		return (error);
```

段描述符走 `vm_get/set_seg_desc`,批量走 `VM_GET/SET_REGISTER_SET`。对应 `KVM_GET/SET_REGS`。

### 10) CPUID 过滤

**内核态 `x86_emulate_cpuid()`** — `sys/amd64/vmm/x86.c:78`

guest 执行 CPUID 触发 VM exit(`EXIT_REASON_CPUID`),内核在此函数按 leaf 重写返回值(屏蔽/伪造特性位、x2apic、topology、xsave 限制等)后写回 rax/rbx/rcx/rdx。

```c
// x86.c:78
int
x86_emulate_cpuid(struct vcpu *vcpu, uint64_t *rax, uint64_t *rbx,
    uint64_t *rcx, uint64_t *rdx)
{
	struct vm *vm = vcpu_vm(vcpu);
	int vcpu_id = vcpu_vcpuid(vcpu);
	...
	unsigned int func, regs[4], logical_cpus, param;
	enum x2apic_state x2apic_state;
	uint16_t cores, maxcpus, sockets, threads;
```

对应 `KVM_SET_CPUID2`(bhyve 在内核实时过滤而非预置表)。

### 11) MSR 模拟

**内核态 `vmx_rdmsr()` / `vmx_wrmsr()`(+ MSR bitmap `guest_msr_rw`)** — `sys/amd64/vmm/intel/vmx_msr.c:403`, `:445`

RDMSR/WRMSR exit 时由 backend 处理:部分 MSR 经 MSR bitmap 直接透传(`guest_msr_rw`),其余在 `vmx_rdmsr`/`vmx_wrmsr` 中按号软件模拟(MTRR、MISC_ENABLE、TSC 等)。

```c
// vmx_msr.c:445
vmx_wrmsr(struct vmx_vcpu *vcpu, u_int num, uint64_t val, bool *retu)
{
	...
	switch (num) {
	case MSR_MCG_CAP:
	case MSR_MCG_STATUS:
		break;		/* ignore writes */
	case MSR_MTRRcap:
	...
		if (vm_wrmtrr(&vcpu->mtrr, num, val) != 0)
			vm_inject_gp(vcpu->vcpu);
		break;
	case MSR_IA32_MISC_ENABLE:
		...
```

透传设置见 `vmx_msr.c:320 guest_msr_rw(vmx, MSR_LSTAR)` 等。对应 `KVM_SET_MSRS` + MSR filter。

### 12) VM exit 分发 [分歧]

**内核态 `vmx_exit_process()`(大 switch on `exit_reason`)** — `sys/amd64/vmm/intel/vmx.c:2371`

与 KVM 类似,bhyve 的 exit 分发在内核完成:大部分(CPUID、MSR、EPT violation、中断窗口、HLT 等)内核直接处理;只有 PIO/MMIO/未知等需要用户态设备模拟的才 `return (UNHANDLED)` 冒泡到 `vm_run` 再返回 `VM_RUN` ioctl 给 bhyve(8)。

```c
// vmx.c:2371
vmx_exit_process(struct vmx *vmx, struct vmx_vcpu *vcpu, struct vm_exit *vmexit)
{
	...
	qual = vmexit->u.vmx.exit_qualification;
	reason = vmexit->u.vmx.exit_reason;
	vmexit->exitcode = VM_EXITCODE_BOGUS;
	vmm_stat_incr(vcpu->vcpu, VMEXIT_COUNT, 1);
	...
	switch (reason) {   // EXIT_REASON_EXCEPTION / CPUID / EPT_FAULT / ...
```

分歧点:相比 KVM,bhyve 内核处理的设备更多(LAPIC/IOAPIC/HPET/RTC 都在内核,见维度 4),冒泡到用户态的 exit 更少。exit_reason 字符串表见 `vmx.c:335 exit_reason_to_str`。

---

## 维度 3: I/O 模型

> bhyve(8) 在用户态做全量设备模拟(AHCI/NVMe/virtio/XHCI),vmm.ko 仅拦截 I/O 指令并按有无内核 handler 决定内核处理或冒泡用户态。

### 13) PIO / MMIO 拦截

**内核态 PIO `emulate_inout_port()` / `vm_handle_inout()`;MMIO 用户态 `access_memory()`/`emulate_mem_cb()`** — `sys/amd64/vmm/vmm_ioport.c:101`, `:195`;`usr.sbin/bhyve/mem.c:169`, `:243`

guest IN/OUT 触发 exit 后,内核查 `ioport_handler[]` 表:有 handler(如 vatpic/vatpit/vrtc)内核直接处理,无则置 `*retu = true` 冒泡用户态。MMIO 则由用户态 `mem.c` 按注册的 `mem_range` 分发到设备回调。

```c
// vmm_ioport.c:101
emulate_inout_port(struct vcpu *vcpu, struct vm_exit *vmexit, bool *retu)
{
	ioport_handler_func_t handler;
	...
	/* If there is no handler for the I/O port then punt to userspace. */
	if (vmexit->u.inout.port >= MAX_IOPORTS ||
	    (handler = ioport_handler[vmexit->u.inout.port]) == NULL) {
		*retu = true;
		return (0);
	}
	...
	error = (*handler)(vcpu_vm(vcpu), vmexit->u.inout.in,
	    vmexit->u.inout.port, vmexit->u.inout.bytes, &val);
```

对应 KVM 的 `KVM_EXIT_IO` / `KVM_EXIT_MMIO`。内核 handler 表见 `vmm_ioport.c:45 ioport_handler[MAX_IOPORTS]`。

### 14) I/O 事件通知(kqueue)

**用户态 `mevent_dispatch()`(kqueue/kevent 事件循环)+ `mevent_add()`** — `usr.sbin/bhyve/mevent.c:133`, `:482`

bhyve(8) 的 I/O 线程用 FreeBSD kqueue 做事件驱动:`kqueue()` 建句柄,`mevent_dispatch` 主循环阻塞在 `kevent()` 等设备 fd/信号/定时器就绪,再 `mevent_handle` 分发。

```c
// mevent.c:133
mfd = kqueue();
...
// mevent.c:523 (mevent_dispatch 主循环内)
	for (;;) {
		numev = mevent_build(changelist);
		if (numev) {
			ret = kevent(mfd, changelist, numev, NULL, 0, NULL);
			...
		}
		/* Block awaiting events */
		ret = kevent(mfd, NULL, 0, eventlist, MEVENT_MAX, NULL);
		...
		mevent_handle(eventlist, ret);
	}
```

对应 Firecracker 的 epoll 事件循环。

### 15) virtio 设备

**用户态 virtio 框架 `vi_softc_linkup()` + 队列 `vq_getchain()`/`vq_relchain()` + `vi_pci_write()`** — `usr.sbin/bhyve/virtio.c:69`, `:271`, `:685`

virtio 公共层:`vi_softc_linkup` 绑定 `struct virtio_consts` 回调;`vq_getchain` 从 virtqueue descriptor ring 取出 guest 提供的 iovec 链供设备处理;MSI-X/PCI 配置经 `vi_pci_write`/`vi_intr_init`。具体设备为 `pci_virtio_block/net/console/...`。

```c
// virtio.c:271
vq_getchain(struct vqueue_info *vq, struct iovec *iov, int niov,
    struct vi_req *vrp)
{
	...  // 遍历 avail ring + descriptor 表,填 iov[]
```

框架初始化 `virtio.c:69 vi_softc_linkup`,中断 `virtio.c:148 vi_intr_init`。对应 Firecracker 的 virtio 设备(bhyve 是纯用户态)。

### 16) 网络后端(TAP)

**用户态 `tap_init()`(open `/dev/tapN`)** — `usr.sbin/bhyve/net_backends.c:88`

打开 `/dev/<tapname>` 得 fd,设非阻塞并向 mevent 注册读通知;`vmnet` 后端复用同一 init。收发经该 fd read/write。

```c
// net_backends.c:88
tap_init(struct net_backend *be, const char *devname, ...)
{
	...
	strcpy(tbuf, "/dev/");
	strlcat(tbuf, devname, sizeof(tbuf));
	be->fd = open(tbuf, O_RDWR);
	if (be->fd == -1) {
		EPRINTLN("open of tap device %s failed", tbuf);
		goto error;
	}
```

后端表见 `net_backends.c:250 .init = tap_init`。对应 Firecracker 的 tap fd。其余后端:netmap(`net_backend_netmap.c`)、slirp(`net_backend_slirp.c`)、netgraph(`net_backend_netgraph.c`)。

### 17) 块设备后端

**用户态 `blockif_open()` + `blockif_read()`/`blockif_write()`(worker 用 `preadv`/`pwritev`)** — `usr.sbin/bhyve/block_if.c:477`, `:780`, `:249`

`blockif_open` 打开后端文件/设备,`blockif_read/write` 排入请求队列,worker 线程用 `preadv`/`pwritev` 向 host fd 做真实 I/O。

```c
// block_if.c:249 (blockif_proc worker 内)
	case BOP_READ:
		if (buf == NULL) {
			if ((n = preadv(bc->bc_fd, br->br_iov, br->br_iovcnt,
			    br->br_offset)) < 0)
				err = errno;
			...
	// block_if.c:290
	case BOP_WRITE:
		... pwritev(bc->bc_fd, br->br_iov, br->br_iovcnt, br->br_offset)
```

供 AHCI(`pci_ahci.c`)、NVMe(`pci_nvme.c`)、virtio-blk 复用。对应 Firecracker 的块设备后端。

### 18) 设备模拟位置 [分歧]

分歧点(bhyve 独有的"内核 + 用户态"双层设备模型):

- **内核 vmm.ko 模拟**:LAPIC(`vlapic.c`)、IOAPIC(`vioapic.c`)、8259 PIC(`vatpic.c`)、8254 PIT(`vatpit.c`)、HPET(`vhpet.c`)、RTC(`vrtc.c`)、PM timer(`vpmtmr.c`)。这些高频/中断相关设备留在内核减少 exit 冒泡。
- **用户态 bhyve(8) 模拟**:AHCI/NVMe/virtio/XHCI/e1000/PCI passthru/framebuffer 等,经 `pci_emul.c` 的 PCI 总线框架挂载。

```c
// vmm_ioport.c:45 — 内核内建 I/O handler 表(节选自表)
ioport_handler_func_t ioport_handler[MAX_IOPORTS] = {
	...   // 8259/8254/RTC 等由内核 handler 直接应答
};
```

对比:KVM 也把 LAPIC/IOAPIC/PIT 放内核(可选),但 bhyve 内核设备集更固定;Firecracker 全用户态。

---

## 维度 4: 中断与事件

### 19) LAPIC 模拟(vmm_lapic)

**内核态 `lapic_set_intr()` / `lapic_intr_msi()`(+ vlapic 后端)** — `sys/amd64/vmm/vmm_lapic.c:51`, `:93`;`sys/amd64/vmm/io/vlapic.c`

LAPIC 在内核模拟。`lapic_set_intr` 把向量置入目标 vlapic 的 IRR(`vlapic_set_intr_ready`)并 `vcpu_notify_event` 踢醒/IPI 该 vCPU;`lapic_intr_msi` 把 MSI 地址/数据解码后投递。

```c
// vmm_lapic.c:51
lapic_set_intr(struct vcpu *vcpu, int vector, bool level)
{
	struct vlapic *vlapic;
	if (vector < 16 || vector > 255)
		return (EINVAL);
	vlapic = vm_lapic(vcpu);
	if (vlapic_set_intr_ready(vlapic, vector, level))
		vcpu_notify_event(vcpu, true);
	return (0);
}
```

IRR 置位在 `vlapic.c:266 vlapic_set_intr_ready`。对应 KVM 的内核 LAPIC。

### 20) IOAPIC 模拟(vioapic)

**内核态 `vioapic_assert_irq()` / `vioapic_deassert_irq()` / `vioapic_pulse_irq()`(→ `vioapic_set_irqstate`)+ `vioapic_init()`** — `sys/amd64/vmm/io/vioapic.c:220`, `:189`, `:495`

24 路 IOAPIC 重定向表在内核模拟。设备拉 IRQ 线经 `vioapic_assert_irq`,内部 `vioapic_set_irqstate` 查重定向表转成 LAPIC 投递。

```c
// vioapic.c:219
int
vioapic_assert_irq(struct vm *vm, int irq)
{
	return (vioapic_set_irqstate(vm, irq, IRQSTATE_ASSERT));
}
```

```c
// vioapic.c:189
static int
vioapic_set_irqstate(struct vm *vm, int irq, enum irqstate irqstate)
{
	...
	VIOAPIC_LOCK(vioapic);
	switch (irqstate) {
	case IRQSTATE_ASSERT:
		vioapic_set_pinstate(vioapic, irq, true);
```

对应 KVM 内核 IOAPIC。

### 21) 中断注入

**内核态 `vm_inject_exception()`/`vm_inject_nmi()`/`vm_inject_extint()`(顶层)+ backend `vmx_inject_interrupts()`/`vmx_inject_nmi()`(写 VMCS)** — `sys/amd64/vmm/vmm.c:2335`, `:2418`, `:2445`;`sys/amd64/vmm/intel/vmx.c:1453`, `:1427`

顶层记录 pending 异常/NMI/extint;VM entry 前 backend 把它写进 `VMCS_ENTRY_INTR_INFO` 完成硬件注入。

```c
// vmx.c:1478 (vmx_inject_interrupts 内)
	info = vmcs_read(VMCS_ENTRY_INTR_INFO);
	...
	info = entryinfo;
	vector = info & 0xff;
	if (vector == IDT_BP || vector == IDT_OF) {
		info &= ~VMCS_INTR_T_MASK;
		info |= VMCS_INTR_T_SWEXCEPTION;
	}
	if (info & VMCS_INTR_DEL_ERRCODE)
		vmcs_write(VMCS_ENTRY_EXCEPTION_ERROR, entryinfo >> 32);
	vmcs_write(VMCS_ENTRY_INTR_INFO, info);
```

用户态经 `VM_INJECT_EXCEPTION` / `VM_LAPIC_IRQ` / `VM_LAPIC_MSI` / `VM_IOAPIC_ASSERT_IRQ` ioctl 触发。对应 `KVM_INTERRUPT` / `KVM_SET_VCPU_EVENTS`。

### 22) 中断通知路径 [分歧]

**内核态 `vcpu_notify_event()` → `ipi_cpu()` / `vlapic_post_intr()` / `wakeup_one()`** — `sys/amd64/vmm/vmm.c:2735`, `:2766`

分歧点:置中断后如何"戳"目标 vCPU。bhyve 内核直接判目标 vCPU 状态:RUNNING 且在别的 host CPU 上 → `ipi_cpu()` 发物理 IPI(`vmm_ipinum`)让其 VM exit;SLEEPING(HLT)→ `wakeup_one()` 唤醒睡眠的内核线程。

```c
// vmm.c:2735
vcpu_notify_event_locked(struct vcpu *vcpu, bool lapic_intr)
{
	int hostcpu;
	hostcpu = vcpu->hostcpu;
	if (vcpu->state == VCPU_RUNNING) {
		if (hostcpu != curcpu) {
			if (lapic_intr)
				vlapic_post_intr(vcpu->vlapic, hostcpu, vmm_ipinum);
			else
				ipi_cpu(hostcpu, vmm_ipinum);
		}
	} else {
		if (vcpu->state == VCPU_SLEEPING)
			wakeup_one(vcpu);
	}
}
```

相比 KVM 靠信号/`kvm_vcpu_kick`,bhyve 直接用 FreeBSD `ipi_cpu`/`wakeup_one` 内核原语(纯内核路径,无用户态信号往返)。

---

## 维度 5: 时钟与定时器

### 23) TSC 虚拟化

**内核态 `vmx_set_tsc_offset()`(写 `VMCS_TSC_OFFSET`)+ `vm_set_tsc_offset()`** — `sys/amd64/vmm/intel/vmx.c:1403`, `sys/amd64/vmm/vmm.c:3129`

bhyve 用硬件 TSC offsetting:置 `PROCBASED_TSC_OFFSET` 控制位并把 offset 写进 VMCS,guest 读 TSC 由硬件自动加 offset,无软件模拟。

```c
// vmx.c:1403
vmx_set_tsc_offset(struct vmx_vcpu *vcpu, uint64_t offset)
{
	if ((vcpu->cap.proc_ctls & PROCBASED_TSC_OFFSET) == 0) {
		vcpu->cap.proc_ctls |= PROCBASED_TSC_OFFSET;
		vmcs_write(VMCS_PRI_PROC_BASED_CTLS, vcpu->cap.proc_ctls);
	}
	error = vmwrite(VMCS_TSC_OFFSET, offset);
	...
}
```

顶层保存 `vmm.c:3129 vm_set_tsc_offset`(`vcpu->tsc_offset`)。AMD 侧对应 VMCB TSC offset/ratio。对应硬件 TSC 虚拟化。

### 24) 高精度定时器源(callout)

**内核态 FreeBSD `callout_init()` / `callout_reset_sbt[_curcpu]()` / `callout_stop()` / `callout_drain()`** — `sys/amd64/vmm/io/vhpet.c:735/355/320/751`,`sys/amd64/vmm/io/vlapic.c:710`

所有内核虚拟定时器(HPET/LAPIC timer/RTC)都用 FreeBSD 内核 `callout` 子系统驱动。

```c
// vhpet.c:355
	callout_reset_sbt(&vhpet->timer[n].callout, vhpet->timer[n].callout_sbt,
	    0, vhpet_timer_expired, &vhpet->arg[n], 0);
// vhpet.c:735
	callout_init(&vhpet->timer[i].callout, 1);
```

对应 axvisor 的 hrtimer / KVM 的 hrtimer。

### 25) 定时器设备模拟(LAPIC timer)

**内核态 `vlapic_callout_reset()` + `vlapic_callout_handler()` + `vlapic_fire_timer()`** — `sys/amd64/vmm/io/vlapic.c:710`, `:716`, `:641`

LAPIC timer 在内核用 per-CPU callout 模拟:`vlapic_callout_reset` 用 `callout_reset_sbt_curcpu` 排定到期,`vlapic_callout_handler` 到期回调,`vlapic_fire_timer` 触发 LVT timer 中断。

```c
// vlapic.c:709
static void
vlapic_callout_reset(struct vlapic *vlapic, sbintime_t t)
{
	callout_reset_sbt_curcpu(&vlapic->callout, t, 0,
	    vlapic_callout_handler, vlapic, 0);
}
// vlapic.c:641
vlapic_fire_timer(struct vlapic *vlapic)
{
	...
	if (vlapic_fire_lvt(vlapic, APIC_LVT_TIMER)) { ... }
}
```

对应 axvisor 内核内 LAPIC timer 投递(bhyve 全在内核,无 TSC-deadline MSR 落空问题)。

### 26) 单调时间获取

**用户态 `clock_gettime(CLOCK_MONOTONIC, ...)`** — `usr.sbin/bhyve/pci_hda.c:1223`, `usr.sbin/bhyve/net_backend_slirp.c:195`

bhyve(8) 各设备取宿主单调时间用 POSIX `clock_gettime`。

```c
// pci_hda.c:1223
	err = clock_gettime(CLOCK_MONOTONIC, &ts);
```

内核侧单调时间用 `sbinuptime()`/`getsbinuptime()`(callout 的 sbintime 基准)。对应 axvisor 的 monotonic 时钟。RTC 挂钟同步另见 `vrtc.c`。

---

## 维度 6: 调度与同步

### 27) 每 vCPU 一线程

**用户态 `pthread_create()` + `fbsdrun_start_thread()` → `vm_loop()`** — `usr.sbin/bhyve/bhyverun.c:458`, `:412`, `:496`

bhyve(8) 为每个 vCPU 建一个 pthread,线程主体 `vm_loop` 循环发 `VM_RUN` ioctl。

```c
// bhyverun.c:458 (fbsdrun_addcpu 内)
	error = vm_activate_cpu(vi->vcpu);
	...
	error = pthread_create(&thr, NULL, fbsdrun_start_thread, vi);
	assert(error == 0);
```

```c
// bhyverun.c:412
fbsdrun_start_thread(void *param)
{
	struct vcpu_info *vi = param;
	...
	pthread_set_name_np(pthread_self(), tname);
	if (vcpumap[vi->vcpuid] != NULL) {
		error = pthread_setaffinity_np(pthread_self(),
		    sizeof(cpuset_t), vcpumap[vi->vcpuid]);
	}
	vm_loop(vi->ctx, vi->vcpu);
}
```

对应 Firecracker 的 vCPU thread、KVM 的 `KVM_RUN` per-thread。

### 28) CPU 亲和性(cpuset)

**用户态 `pthread_setaffinity_np()`(基于 FreeBSD cpuset_t)** — `usr.sbin/bhyve/bhyverun.c:422`

绑定 vCPU 线程到指定 host CPU。注意:参考树中 bhyve **未直接调 `cpuset_setaffinity(2)` 系统调用**,而是走 pthread 封装 `pthread_setaffinity_np`(其底层即 FreeBSD cpuset),CPU 集合用 `CPU_SET` 宏构造(`bhyverun.c:341/346`)。

```c
// bhyverun.c:421
	if (vcpumap[vi->vcpuid] != NULL) {
		error = pthread_setaffinity_np(pthread_self(),
		    sizeof(cpuset_t), vcpumap[vi->vcpuid]);
		assert(error == 0);
	}
```

对应任务要求的 `cpuset_setaffinity` 语义(bhyve 用 pthread 层等价接口)。

### 29) vCPU 休眠 / 唤醒(HALT)

**内核态 `vm_handle_hlt()`(`msleep_spin` 睡)+ `vcpu_notify_event`(`wakeup_one` 醒)** — `sys/amd64/vmm/vmm.c:1602`, `:1673`;唤醒见维度 4 的 `vmm.c:2761`

guest HLT 触发内核 `vm_handle_hlt`:置 `VCPU_SLEEPING` 后用 `msleep_spin` 睡在 vCPU 锁上;有中断到来时 `vcpu_notify_event_locked` 调 `wakeup_one` 唤醒。全程在内核,不冒泡用户态。

```c
// vmm.c:1667 (vm_handle_hlt 内)
	t = ticks;
	vcpu_require_state_locked(vcpu, VCPU_SLEEPING);
	/*
	 * XXX msleep_spin() cannot be interrupted by signals so
	 * wake up periodically to check pending signals.
	 */
	msleep_spin(vcpu, &vcpu->mtx, wmesg, hz);
	vcpu_require_state_locked(vcpu, VCPU_FROZEN);
```

对应 KVM 的 `kvm_vcpu_block` / halt-polling。bhyve 的 HLT 全在内核处理,是与 Firecracker(用户态 KVM_EXIT_HLT)的差异。

### 30) 事件循环(kqueue)

**用户态 `mevent_dispatch()`(kqueue/kevent)** — `usr.sbin/bhyve/mevent.c:482`(片段见维度 3 第 14 项)

bhyve(8) 的设备 I/O 线程用 kqueue 事件循环,与 vCPU 线程解耦。对应 Firecracker 的 epoll 主循环。

### 31) 锁原语(mtx / sx / rw)

**内核态 FreeBSD `mtx_init/mtx_lock`(spin/sleep mutex)、`sx_init/sx_xlock`(shared/exclusive)** — `sys/amd64/vmm/vmm.c:127`, `:601`, `:602`

vmm.ko 广泛用 FreeBSD 内核锁:vCPU 锁用 spin mutex,VM 级内存段/vCPU 初始化用 sx 锁,rendezvous 用 sleep mutex。

```c
// vmm.c:127
#define	vcpu_lock_init(v)	mtx_init(&((v)->mtx), "vcpu lock", 0, MTX_SPIN)
// vmm.c:601
	mtx_init(&vm->rendezvous_mtx, "vm rendezvous lock", 0, MTX_DEF);
	sx_init(&vm->mem_segs_lock, "vm mem_segs");
	sx_init(&vm->vcpus_init_lock, "vm vcpus");
```

用户态设备线程用 `pthread_mutex`/`pthread_cond`。对应 axvisor 的 SpinNoIrq / KVM 的 spinlock+mutex。

### 32) 抢占通知 [可选]

**内核态跨 CPU 同步用 `smp_rendezvous()`;无 KVM 式 preempt-notifier 注册** — `sys/amd64/vmm/intel/ept.c:170`,`sys/amd64/vmm/amd/svm.c:274`

bhyve 不注册 Linux/KVM 式 preempt notifier。跨 CPU 一致性(EPT TLB 刷新、VMX/SVM 使能广播)用 FreeBSD `smp_rendezvous`;vCPU 迁移时 FPU/MSR 的保存恢复由 `vm_run` 每次进出 guest 显式做(`restore_guest_fpustate`/`save_guest_fpustate`,`vmm.c:2047/2053`)。

```c
// svm.c:274
	smp_rendezvous(NULL, svm_enable, NULL, NULL);
// ept.c:170 (EPT TLB 全局失效)
	smp_rendezvous(NULL, invept_single_context, NULL, &invept_desc);
```

分歧:KVM 靠 `preempt_notifier` 在被抢占/恢复时切换 VMCS;bhyve 在 `critical_enter()`(`vmm.c:2037`)临界区内运行 guest,并在每次 VM entry 显式加载状态。

---

## 维度 7: 安全与隔离

### 33) 权限检查(priv_check)

**内核态 `vmm_priv_check()`(基于 jail allow 标志)** — `sys/amd64/vmm/vmm_dev.c:149`,在各 ioctl 入口调用(`:249`, `:444`, `:1099` 等)

bhyve 的 /dev/vmm ioctl 入口都先过 `vmm_priv_check`。它不用通用 `priv_check(9)`,而是检查:若进程在 jail 中,须有 `allow.vmm` 权限,否则 `EPERM`。基础访问控制由设备节点权限(见第 36 项)兜底。

```c
// vmm_dev.c:148
static int
vmm_priv_check(struct ucred *ucred)
{
	if (jailed(ucred) &&
	    !(ucred->cr_prison->pr_allow & pr_allow_flag))
		return (EPERM);
	return (0);
}
```

对应任务要求的 `priv_check` 语义(bhyve 用 jail-aware 变体)。

### 34) 进程沙箱(Capsicum)

**用户态 `caph_enter()`(= `cap_enter`)+ per-fd `cap_rights_limit()`/`cap_rights_init()`** — `usr.sbin/bhyve/bhyverun.c:1033`;设备侧如 `usr.sbin/bhyve/net_backends.c:128`

初始化(打开所有设备、建 vCPU 线程)完成后调 `caph_enter` 进入 Capsicum capability 模式,之后不能再 open 新文件;每个 fd 用 `cap_rights_limit` 收窄为最小权限集。

```c
// bhyverun.c:1030
	if (caph_limit_stdout() == -1 || caph_limit_stderr() == -1)
		errx(EX_OSERR, "Unable to apply rights for sandbox");
	if (caph_enter() == -1)
		errx(EX_OSERR, "cap_enter() failed");
```

```c
// net_backends.c:128 (tap 后端限权)
	cap_rights_init(&rights, CAP_EVENT, CAP_READ, CAP_WRITE);
```

对应 Firecracker 的 seccomp(bhyve 用 FreeBSD Capsicum)。

### 35) 资源限制(jail / rctl)

**内核态 jail 集成 `prison_add_allow(..., "vmm", ...)` + `jailed()` 判定** — `sys/amd64/vmm/vmm_dev.c:1334`, `:152`

bhyve 支持在 FreeBSD jail 内运行,由 `vmmdev_init` 注册 `allow.vmm` jail 参数;运行时 `vmm_priv_check` 用 `jailed()` 判定。

```c
// vmm_dev.c:1331
void
vmmdev_init(void)
{
	pr_allow_flag = prison_add_allow(NULL, "vmm", NULL,
	    "Allow use of vmm in a jail.");
}
```

**rctl / racct 资源计量:未在参考树的 `sys/amd64/vmm/` 与 `usr.sbin/bhyve/` 中找到直接调用**(grep `racct`/`rctl_` 无内核态命中;`rctl` 仅命中 e1000 的 RCTL 寄存器,与资源限制无关)。VM 内存等资源限制主要靠 jail 层与 host 内存 wired 上限,而非 vmm 显式 rctl 调用。

### 36) 设备访问控制

**内核态 `make_dev_p()`(UID_ROOT / GID_WHEEL / 0600 权限)** — `sys/amd64/vmm/vmm_dev.c:1310`(`/dev/vmm/<name>`)、`:1401`(`/dev/vmm.io/<name>`)

每个 VM 一个设备节点,创建时用 `sc->ucred` 归属创建者、模式 0600,构成 DAC 层访问控制;`vmmdevsw` cdevsw 定义 open/ioctl 处理入口。

```c
// vmm_dev.c:1310
	error = make_dev_p(MAKEDEV_CHECKNAME, &cdev, &vmmdevsw, sc->ucred,
	    UID_ROOT, GID_WHEEL, 0600, "vmm/%s", buf);
// vmm_dev.c:1401 (设备内存节点)
	error = make_dev_p(MAKEDEV_CHECKNAME, &cdev, &devmemsw, NULL,
	    UID_ROOT, GID_WHEEL, 0600, "vmm.io/%s.%s", vmname, devname);
```

对应 KVM `/dev/kvm`(单节点)、Firecracker 的 fd 权限;bhyve 是"每 VM 一个 0600 设备节点"。

---

## 统计

36 个接口全部处理完毕。按主实现所在层分类:

- **内核态 vmm.ko(`sys/amd64/vmm/`)为主实现**:约 22 项
  1(内核段分配)、2、3、5(分歧说明,内核 pmap/invept)、6、7、8、9、10、11、12、18(内核设备部分)、19、20、21、22、23、24、25、31、32、33、35(jail 内核集成)、36。
- **用户态 bhyve(8)(`usr.sbin/bhyve/` + libvmmapi)为主实现**:约 11 项
  1(用户态双重映射)、13(MMIO 用户态)、14、15、16、17、18(用户态设备部分)、26、27、28、29(唤醒链跨层)、30、34。
  说明:第 1、13、18 项跨内核/用户态双层,已在两侧分别给源码。
- **未在参考树中找到(标注但未编造)**:
  - 第 4 项 脏页追踪:无独立脏页位图 / `VM_GET_DIRTY_LOG` 接口(仅有 EPT A/D 位模拟 `pmap_emulate_accessed_dirty`)。
  - 第 5 项 MMU 反向通知:无 `mmu_notifier` 机制(设计上不需要,已说明)。
  - 第 35 项内的 rctl/racct 资源计量:参考树中未找到直接调用(jail 集成本身已找到)。

其余 34 个接口均给出了真实 FreeBSD/bhyve 函数名 + 相对路径:行号 + 源码片段。

### 关键差异小结(相对 KVM / Firecracker)

- 内核态承担更多:LAPIC/IOAPIC/PIC/PIT/HPET/RTC/PM-timer 全在 vmm.ko(第 18 项),HLT 也在内核处理(第 29 项),冒泡到用户态的 exit 更少(第 12 项)。
- 通知路径纯内核:`vcpu_notify_event` 直接用 `ipi_cpu`/`wakeup_one`,不走用户态信号(第 22 项)。
- 沙箱用 Capsicum 而非 seccomp(第 34 项);权限用 jail-aware `vmm_priv_check` 而非通用 `priv_check`(第 33 项)。
- 亲和性用 `pthread_setaffinity_np` 而非直接 `cpuset_setaffinity(2)`(第 28 项)。
- 每 VM 一个 0600 设备节点 `/dev/vmm/<name>`,而非 KVM 单一 `/dev/kvm`(第 36 项)。
