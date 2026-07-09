// SPDX-License-Identifier: GPL-2.0-only
/*
 * Firecracker-oriented KVM ABI smoke for AxVisor-backed /dev/kvm.
 *
 * This is not a Firecracker replacement and it is not the final acceptance
 * test. It compresses the x86_64 Firecracker cold-boot KVM initialization
 * path into one userspace program so the next ABI failure is concrete.
 *
 * Build:
 *   cc -O2 -Wall -Wextra -o /tmp/axvisor-kvm-firecracker-init-smoke \
 *     tools/axvisor-kvm-firecracker-init-smoke.c
 *
 * Run:
 *   KVM_DEV=/dev/kvm /tmp/axvisor-kvm-firecracker-init-smoke
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "This smoke models Firecracker's x86_64 KVM initialization path."
#endif

#define FC_CPUID_ENTRIES 256
#define FC_MSR_ENTRIES 512
#define FC_GUEST_MEM_SIZE (64UL * 1024UL * 1024UL)

#define FC_BOOT_IP 0x100000ULL
#define FC_BOOT_STACK_POINTER 0x8ff0ULL
#define FC_ZERO_PAGE_START 0x7000ULL
#define FC_KVM_TSS_ADDRESS 0xfffbd000UL

#define FC_BOOT_GDT_OFFSET 0x500ULL
#define FC_BOOT_IDT_OFFSET 0x520ULL
#define FC_PML4_START 0x9000ULL
#define FC_PDPTE_START 0xa000ULL
#define FC_PDE_START 0xb000ULL

#define FC_EFER_LME 0x100ULL
#define FC_EFER_LMA 0x400ULL
#define FC_CR0_PE 0x1ULL
#define FC_CR0_PG 0x80000000ULL
#define FC_CR4_PAE 0x20ULL

#define FC_APIC_LVT0 0x350
#define FC_APIC_LVT1 0x360
#define FC_APIC_MODE_NMI 0x4
#define FC_APIC_MODE_EXTINT 0x7

#define FC_VIRTIO_MMIO_BASE 0xd0000000ULL
#define FC_VIRTIO_MMIO_NOTIFY_OFFSET 0x50ULL
#define FC_VIRTIO_MMIO_IRQ 5

#define MSR_IA32_TSC 0x00000010U
#define MSR_IA32_SYSENTER_CS 0x00000174U
#define MSR_IA32_SYSENTER_ESP 0x00000175U
#define MSR_IA32_SYSENTER_EIP 0x00000176U
#define MSR_IA32_MISC_ENABLE 0x000001a0U
#define MSR_IA32_MISC_ENABLE_FAST_STRING 0x1U
#define MSR_IA32_APICBASE_BSP (1ULL << 8)
#define MSR_IA32_APICBASE_ENABLE (1ULL << 11)
#define APIC_DEFAULT_PHYS_BASE 0xfee00000ULL
#define MSR_STAR 0xc0000081U
#define MSR_LSTAR 0xc0000082U
#define MSR_CSTAR 0xc0000083U
#define MSR_SYSCALL_MASK 0xc0000084U
#define MSR_KERNEL_GS_BASE 0xc0000102U

static void die_errno(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(1);
}

static void die_msg(const char *what)
{
	fprintf(stderr, "%s\n", what);
	exit(1);
}

static long kvm_ioctl(int fd, unsigned long request, void *arg,
		      const char *name)
{
	long ret = ioctl(fd, request, arg);

	if (ret < 0)
		die_errno(name);
	return ret;
}

static void check_cap(int kvm_fd, int cap, const char *name)
{
	int ret = ioctl(kvm_fd, KVM_CHECK_EXTENSION, cap);

	if (ret <= 0) {
		fprintf(stderr, "%s is not available\n", name);
		exit(1);
	}
}

static void write_u64(void *mem, uint64_t gpa, uint64_t val)
{
	memcpy((char *)mem + gpa, &val, sizeof(val));
}

static uint64_t gdt_entry(uint32_t flags, uint32_t base, uint32_t limit)
{
	uint64_t entry = 0;

	entry |= limit & 0xffffULL;
	entry |= (base & 0xffffffULL) << 16;
	entry |= (uint64_t)flags << 40;
	entry |= ((uint64_t)(limit >> 16) & 0xfULL) << 48;
	entry |= ((uint64_t)(base >> 24) & 0xffULL) << 56;
	return entry;
}

static struct kvm_segment segment_from_gdt(uint64_t entry, uint16_t selector)
{
	struct kvm_segment seg = {};

	seg.base = ((entry >> 16) & 0xffffffULL) |
		   ((entry >> 32) & 0xff000000ULL);
	seg.limit = (entry & 0xffffU) | ((entry >> 32) & 0xf0000U);
	if (entry & (1ULL << 55))
		seg.limit = (seg.limit << 12) | 0xfffU;
	seg.selector = selector;
	seg.type = (entry >> 40) & 0xf;
	seg.s = (entry >> 44) & 0x1;
	seg.dpl = (entry >> 45) & 0x3;
	seg.present = (entry >> 47) & 0x1;
	seg.avl = (entry >> 52) & 0x1;
	seg.l = (entry >> 53) & 0x1;
	seg.db = (entry >> 54) & 0x1;
	seg.g = (entry >> 55) & 0x1;
	seg.unusable = !seg.present;
	return seg;
}

static void setup_firecracker_sregs(void *guest_mem, struct kvm_sregs *sregs)
{
	uint64_t gdt[4] = {
		0,
		gdt_entry(0xa09b, 0, 0xfffff),
		gdt_entry(0xc093, 0, 0xfffff),
		gdt_entry(0x808b, 0, 0xfffff),
	};
	uint64_t i;

	for (i = 0; i < 4; i++)
		write_u64(guest_mem, FC_BOOT_GDT_OFFSET + i * 8, gdt[i]);
	write_u64(guest_mem, FC_BOOT_IDT_OFFSET, 0);

	sregs->gdt.base = FC_BOOT_GDT_OFFSET;
	sregs->gdt.limit = sizeof(gdt) - 1;
	sregs->idt.base = FC_BOOT_IDT_OFFSET;
	sregs->idt.limit = sizeof(uint64_t) - 1;
	sregs->cs = segment_from_gdt(gdt[1], 1 << 3);
	sregs->ds = segment_from_gdt(gdt[2], 2 << 3);
	sregs->es = segment_from_gdt(gdt[2], 2 << 3);
	sregs->fs = segment_from_gdt(gdt[2], 2 << 3);
	sregs->gs = segment_from_gdt(gdt[2], 2 << 3);
	sregs->ss = segment_from_gdt(gdt[2], 2 << 3);
	sregs->tr = segment_from_gdt(gdt[3], 3 << 3);

	write_u64(guest_mem, FC_PML4_START, FC_PDPTE_START | 0x3);
	write_u64(guest_mem, FC_PDPTE_START, FC_PDE_START | 0x3);
	for (i = 0; i < 512; i++)
		write_u64(guest_mem, FC_PDE_START + i * 8,
			  (i << 21) | 0x83);

	sregs->cr3 = FC_PML4_START;
	sregs->cr4 |= FC_CR4_PAE;
	sregs->cr0 |= FC_CR0_PE | FC_CR0_PG;
	sregs->efer |= FC_EFER_LME | FC_EFER_LMA;
}

static void check_default_sregs(const struct kvm_sregs *sregs)
{
	uint64_t expected_apic_base = APIC_DEFAULT_PHYS_BASE |
				      MSR_IA32_APICBASE_ENABLE |
				      MSR_IA32_APICBASE_BSP;

	if ((sregs->apic_base & expected_apic_base) != expected_apic_base)
		die_msg("KVM_GET_SREGS returned invalid default APIC base");
	if (!sregs->ldt.unusable)
		die_msg("KVM_GET_SREGS returned usable all-zero LDTR");
}

static void check_boot_sregs(int vcpu_fd)
{
	struct kvm_sregs sregs = {};

	kvm_ioctl(vcpu_fd, KVM_GET_SREGS, &sregs, "KVM_GET_SREGS verify");
	if (!sregs.ldt.unusable)
		die_msg("KVM_SET_SREGS did not preserve unusable LDTR");
	if ((sregs.apic_base & MSR_IA32_APICBASE_ENABLE) == 0)
		die_msg("KVM_SET_SREGS disabled APIC base unexpectedly");
}

static uint32_t lapic_read_u32(const struct kvm_lapic_state *lapic,
			       size_t offset)
{
	uint32_t val;

	memcpy(&val, lapic->regs + offset, sizeof(val));
	return val;
}

static void lapic_write_u32(struct kvm_lapic_state *lapic, size_t offset,
			    uint32_t val)
{
	memcpy(lapic->regs + offset, &val, sizeof(val));
}

static void setup_firecracker_lint(int vcpu_fd)
{
	struct kvm_lapic_state lapic = {};
	uint32_t lint0;
	uint32_t lint1;

	kvm_ioctl(vcpu_fd, KVM_GET_LAPIC, &lapic, "KVM_GET_LAPIC");
	lint0 = lapic_read_u32(&lapic, FC_APIC_LVT0);
	lint1 = lapic_read_u32(&lapic, FC_APIC_LVT1);
	lapic_write_u32(&lapic, FC_APIC_LVT0,
			(lint0 & ~0x700U) | (FC_APIC_MODE_EXTINT << 8));
	lapic_write_u32(&lapic, FC_APIC_LVT1,
			(lint1 & ~0x700U) | (FC_APIC_MODE_NMI << 8));
	kvm_ioctl(vcpu_fd, KVM_SET_LAPIC, &lapic, "KVM_SET_LAPIC");
}

static void check_xcrs_roundtrip(int vcpu_fd)
{
#ifdef KVM_GET_XCRS
	struct kvm_xcrs xcrs = {};
	uint64_t xcr0 = 0x3;
	uint32_t i;

	xcrs.nr_xcrs = 1;
	xcrs.xcrs[0].xcr = 0;
	xcrs.xcrs[0].value = xcr0;
	kvm_ioctl(vcpu_fd, KVM_SET_XCRS, &xcrs, "KVM_SET_XCRS");

	memset(&xcrs, 0, sizeof(xcrs));
	kvm_ioctl(vcpu_fd, KVM_GET_XCRS, &xcrs, "KVM_GET_XCRS");
	for (i = 0; i < xcrs.nr_xcrs; i++) {
		if (xcrs.xcrs[i].xcr == 0 && xcrs.xcrs[i].value == xcr0)
			return;
	}
	die_msg("KVM_GET_XCRS did not preserve XCR0");
#else
	(void)vcpu_fd;
#endif
}

static void check_fpu_roundtrip(int vcpu_fd)
{
	struct kvm_fpu fpu = {};
	struct kvm_fpu got = {};

	fpu.fcw = 0x37f;
	fpu.fsw = 0x5a5a;
	fpu.ftwx = 0xff;
	fpu.last_opcode = 0x1234;
	fpu.last_ip = 0x1122334455667788ULL;
	fpu.last_dp = 0x8877665544332211ULL;
	fpu.mxcsr = 0x1f80;
	fpu.fpr[0][0] = 0xa5;
	fpu.xmm[0][0] = 0x5a;

	kvm_ioctl(vcpu_fd, KVM_SET_FPU, &fpu, "KVM_SET_FPU roundtrip");
	kvm_ioctl(vcpu_fd, KVM_GET_FPU, &got, "KVM_GET_FPU roundtrip");
	if (got.fcw != fpu.fcw || got.fsw != fpu.fsw ||
	    got.ftwx != fpu.ftwx || got.last_opcode != fpu.last_opcode ||
	    got.last_ip != fpu.last_ip || got.last_dp != fpu.last_dp ||
	    got.mxcsr != fpu.mxcsr || got.fpr[0][0] != fpu.fpr[0][0] ||
	    got.xmm[0][0] != fpu.xmm[0][0])
		die_msg("KVM_GET_FPU did not preserve KVM_SET_FPU state");
}

static void check_xsave_roundtrip(int vcpu_fd)
{
#ifdef KVM_GET_XSAVE
	struct kvm_xsave xsave = {};
	struct kvm_xsave got = {};

	xsave.region[0] = 0x037f;
	xsave.region[6] = 0x00001f80;
	xsave.region[7] = 0x0000ffbf;
	xsave.region[40] = 0xabcdef01;

	kvm_ioctl(vcpu_fd, KVM_SET_XSAVE, &xsave, "KVM_SET_XSAVE roundtrip");
	kvm_ioctl(vcpu_fd, KVM_GET_XSAVE, &got, "KVM_GET_XSAVE roundtrip");
	if (got.region[0] != xsave.region[0] ||
	    got.region[6] != xsave.region[6] ||
	    got.region[7] != xsave.region[7] ||
	    got.region[40] != xsave.region[40])
		die_msg("KVM_GET_XSAVE did not preserve KVM_SET_XSAVE state");
#else
	(void)vcpu_fd;
#endif
}

static void get_supported_cpuid(int kvm_fd,
				struct kvm_cpuid2 **out_cpuid,
				size_t *out_size)
{
	size_t size = sizeof(struct kvm_cpuid2) +
		      FC_CPUID_ENTRIES * sizeof(struct kvm_cpuid_entry2);
	struct kvm_cpuid2 *cpuid = calloc(1, size);

	if (!cpuid)
		die_errno("calloc cpuid");
	cpuid->nent = FC_CPUID_ENTRIES;
	kvm_ioctl(kvm_fd, KVM_GET_SUPPORTED_CPUID, cpuid,
		  "KVM_GET_SUPPORTED_CPUID");
	if (!cpuid->nent)
		die_msg("KVM_GET_SUPPORTED_CPUID returned no entries");

	*out_cpuid = cpuid;
	*out_size = size;
}

static void get_msr_index_list(int kvm_fd)
{
	size_t size = sizeof(struct kvm_msr_list) +
		      FC_MSR_ENTRIES * sizeof(uint32_t);
	struct kvm_msr_list *msrs = calloc(1, size);

	if (!msrs)
		die_errno("calloc msr list");
	msrs->nmsrs = FC_MSR_ENTRIES;
	kvm_ioctl(kvm_fd, KVM_GET_MSR_INDEX_LIST, msrs,
		  "KVM_GET_MSR_INDEX_LIST");
	if (!msrs->nmsrs)
		die_msg("KVM_GET_MSR_INDEX_LIST returned no entries");
	free(msrs);
}

static void set_boot_msrs(int vcpu_fd)
{
	struct {
		struct kvm_msrs hdr;
		struct kvm_msr_entry entries[10];
	} msrs = {};
	int ret;

	msrs.hdr.nmsrs = 10;
	msrs.entries[0].index = MSR_IA32_SYSENTER_CS;
	msrs.entries[1].index = MSR_IA32_SYSENTER_ESP;
	msrs.entries[2].index = MSR_IA32_SYSENTER_EIP;
	msrs.entries[3].index = MSR_STAR;
	msrs.entries[4].index = MSR_CSTAR;
	msrs.entries[5].index = MSR_KERNEL_GS_BASE;
	msrs.entries[6].index = MSR_SYSCALL_MASK;
	msrs.entries[7].index = MSR_LSTAR;
	msrs.entries[8].index = MSR_IA32_TSC;
	msrs.entries[9].index = MSR_IA32_MISC_ENABLE;
	msrs.entries[9].data = MSR_IA32_MISC_ENABLE_FAST_STRING;

	ret = ioctl(vcpu_fd, KVM_SET_MSRS, &msrs);
	if (ret != (int)msrs.hdr.nmsrs)
		die_errno("KVM_SET_MSRS boot entries");

	memset(msrs.entries, 0, sizeof(msrs.entries));
	msrs.hdr.nmsrs = 10;
	msrs.entries[0].index = MSR_IA32_SYSENTER_CS;
	msrs.entries[1].index = MSR_IA32_SYSENTER_ESP;
	msrs.entries[2].index = MSR_IA32_SYSENTER_EIP;
	msrs.entries[3].index = MSR_STAR;
	msrs.entries[4].index = MSR_CSTAR;
	msrs.entries[5].index = MSR_KERNEL_GS_BASE;
	msrs.entries[6].index = MSR_SYSCALL_MASK;
	msrs.entries[7].index = MSR_LSTAR;
	msrs.entries[8].index = MSR_IA32_TSC;
	msrs.entries[9].index = MSR_IA32_MISC_ENABLE;
	ret = ioctl(vcpu_fd, KVM_GET_MSRS, &msrs);
	if (ret != (int)msrs.hdr.nmsrs)
		die_errno("KVM_GET_MSRS boot entries");
	if (msrs.entries[9].data != MSR_IA32_MISC_ENABLE_FAST_STRING)
		die_msg("KVM_GET_MSRS did not preserve IA32_MISC_ENABLE");
}

static int create_eventfd(void)
{
	int fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);

	if (fd < 0)
		die_errno("eventfd");
	return fd;
}

static void register_firecracker_eventfds(int vm_fd)
{
	struct kvm_ioeventfd ioevent = {};
	struct kvm_irqfd irqfd = {};
	int notify_fd = create_eventfd();
	int irq_fd = create_eventfd();

	ioevent.fd = notify_fd;
	ioevent.addr = FC_VIRTIO_MMIO_BASE + FC_VIRTIO_MMIO_NOTIFY_OFFSET;
	ioevent.len = 4;
	ioevent.datamatch = 0;
	ioevent.flags = KVM_IOEVENTFD_FLAG_DATAMATCH;
	kvm_ioctl(vm_fd, KVM_IOEVENTFD, &ioevent, "KVM_IOEVENTFD");

	irqfd.fd = irq_fd;
	irqfd.gsi = FC_VIRTIO_MMIO_IRQ;
	kvm_ioctl(vm_fd, KVM_IRQFD, &irqfd, "KVM_IRQFD");

	ioevent.flags |= KVM_IOEVENTFD_FLAG_DEASSIGN;
	kvm_ioctl(vm_fd, KVM_IOEVENTFD, &ioevent, "KVM_IOEVENTFD deassign");
	irqfd.flags = KVM_IRQFD_FLAG_DEASSIGN;
	kvm_ioctl(vm_fd, KVM_IRQFD, &irqfd, "KVM_IRQFD deassign");
	close(irq_fd);
	close(notify_fd);
}

int main(void)
{
	const char *kvm_dev = getenv("KVM_DEV");
	struct kvm_cpuid2 *cpuid = NULL;
	struct kvm_userspace_memory_region region = {};
	struct kvm_pit_config pit = { .flags = KVM_PIT_SPEAKER_DUMMY };
	struct kvm_regs regs = {};
	struct kvm_sregs sregs = {};
	struct kvm_fpu fpu = {};
	struct kvm_mp_state mp_state = { .mp_state = KVM_MP_STATE_RUNNABLE };
	struct kvm_run *run;
	void *guest_mem;
	size_t cpuid_size = 0;
	int mmap_size;
	int kvm_fd;
	int vm_fd;
	int vcpu_fd;
	int ret;

	if (!kvm_dev)
		kvm_dev = "/dev/kvm";

	kvm_fd = open(kvm_dev, O_RDWR | O_CLOEXEC);
	if (kvm_fd < 0)
		die_errno("open KVM device");
	if (ioctl(kvm_fd, KVM_GET_API_VERSION, 0) != KVM_API_VERSION)
		die_msg("KVM_GET_API_VERSION mismatch");

	check_cap(kvm_fd, KVM_CAP_IRQCHIP, "KVM_CAP_IRQCHIP");
	check_cap(kvm_fd, KVM_CAP_USER_MEMORY, "KVM_CAP_USER_MEMORY");
	check_cap(kvm_fd, KVM_CAP_SET_TSS_ADDR, "KVM_CAP_SET_TSS_ADDR");
	check_cap(kvm_fd, KVM_CAP_PIT2, "KVM_CAP_PIT2");
#ifdef KVM_CAP_PIT_STATE2
	check_cap(kvm_fd, KVM_CAP_PIT_STATE2, "KVM_CAP_PIT_STATE2");
#endif
	check_cap(kvm_fd, KVM_CAP_ADJUST_CLOCK, "KVM_CAP_ADJUST_CLOCK");
#ifdef KVM_CAP_DEBUGREGS
	check_cap(kvm_fd, KVM_CAP_DEBUGREGS, "KVM_CAP_DEBUGREGS");
#endif
	check_cap(kvm_fd, KVM_CAP_MP_STATE, "KVM_CAP_MP_STATE");
#ifdef KVM_CAP_VCPU_EVENTS
	check_cap(kvm_fd, KVM_CAP_VCPU_EVENTS, "KVM_CAP_VCPU_EVENTS");
#endif
#ifdef KVM_CAP_XCRS
	check_cap(kvm_fd, KVM_CAP_XCRS, "KVM_CAP_XCRS");
#endif
#ifdef KVM_CAP_XSAVE
	check_cap(kvm_fd, KVM_CAP_XSAVE, "KVM_CAP_XSAVE");
#endif
	check_cap(kvm_fd, KVM_CAP_EXT_CPUID, "KVM_CAP_EXT_CPUID");
	check_cap(kvm_fd, KVM_CAP_NR_MEMSLOTS, "KVM_CAP_NR_MEMSLOTS");
	check_cap(kvm_fd, KVM_CAP_IOEVENTFD, "KVM_CAP_IOEVENTFD");
	check_cap(kvm_fd, KVM_CAP_IRQFD, "KVM_CAP_IRQFD");

	mmap_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < (int)sizeof(*run))
		die_msg("KVM_GET_VCPU_MMAP_SIZE is too small");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		die_errno("KVM_CREATE_VM");

	get_supported_cpuid(kvm_fd, &cpuid, &cpuid_size);
	get_msr_index_list(kvm_fd);

	guest_mem = mmap(NULL, FC_GUEST_MEM_SIZE, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (guest_mem == MAP_FAILED)
		die_errno("mmap guest memory");

	region.slot = 0;
	region.guest_phys_addr = 0;
	region.memory_size = FC_GUEST_MEM_SIZE;
	region.userspace_addr = (uintptr_t)guest_mem;
	kvm_ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region,
		  "KVM_SET_USER_MEMORY_REGION");
	kvm_ioctl(vm_fd, KVM_SET_TSS_ADDR, (void *)FC_KVM_TSS_ADDRESS,
		  "KVM_SET_TSS_ADDR");
	kvm_ioctl(vm_fd, KVM_CREATE_IRQCHIP, 0, "KVM_CREATE_IRQCHIP");
	kvm_ioctl(vm_fd, KVM_CREATE_PIT2, &pit, "KVM_CREATE_PIT2");
	register_firecracker_eventfds(vm_fd);

	vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
	if (vcpu_fd < 0)
		die_errno("KVM_CREATE_VCPU");

	run = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		   vcpu_fd, 0);
	if (run == MAP_FAILED)
		die_errno("mmap kvm_run");

	kvm_ioctl(vcpu_fd, KVM_SET_CPUID2, cpuid, "KVM_SET_CPUID2");
	set_boot_msrs(vcpu_fd);

	regs.rflags = 0x2;
	regs.rip = FC_BOOT_IP;
	regs.rsp = FC_BOOT_STACK_POINTER;
	regs.rbp = FC_BOOT_STACK_POINTER;
	regs.rsi = FC_ZERO_PAGE_START;
	kvm_ioctl(vcpu_fd, KVM_SET_REGS, &regs, "KVM_SET_REGS");

	fpu.fcw = 0x37f;
	fpu.mxcsr = 0x1f80;
	kvm_ioctl(vcpu_fd, KVM_SET_FPU, &fpu, "KVM_SET_FPU");
	check_fpu_roundtrip(vcpu_fd);
	check_xsave_roundtrip(vcpu_fd);
	check_xcrs_roundtrip(vcpu_fd);
	kvm_ioctl(vcpu_fd, KVM_GET_SREGS, &sregs, "KVM_GET_SREGS");
	check_default_sregs(&sregs);
	setup_firecracker_sregs(guest_mem, &sregs);
	kvm_ioctl(vcpu_fd, KVM_SET_SREGS, &sregs, "KVM_SET_SREGS");
	check_boot_sregs(vcpu_fd);
	setup_firecracker_lint(vcpu_fd);
	kvm_ioctl(vcpu_fd, KVM_SET_MP_STATE, &mp_state, "KVM_SET_MP_STATE");
#ifdef KVM_KVMCLOCK_CTRL
	kvm_ioctl(vcpu_fd, KVM_KVMCLOCK_CTRL, 0, "KVM_KVMCLOCK_CTRL");
#endif

	run->immediate_exit = 1;
	ret = ioctl(vcpu_fd, KVM_RUN, 0);
	if (ret != -1 || errno != EINTR)
		die_msg("KVM_RUN immediate_exit did not return EINTR");
	if (run->immediate_exit != 1)
		die_msg("KVM_RUN did not preserve immediate_exit");

	printf("AXVISOR_KVM_FIRECRACKER_INIT_SMOKE_PASS=1\n");
	printf("KVM_DEV=%s\n", kvm_dev);
	printf("KVM_VCPU_MMAP_SIZE=%d\n", mmap_size);
	printf("KVM_SUPPORTED_CPUID_NENT=%u\n", cpuid->nent);
	printf("KVM_FIRECRACKER_X86_INIT_ABI=1\n");

	munmap(run, mmap_size);
	close(vcpu_fd);
	munmap(guest_mem, FC_GUEST_MEM_SIZE);
	close(vm_fd);
	close(kvm_fd);
	free(cpuid);
	(void)cpuid_size;
	return 0;
}
