// SPDX-License-Identifier: GPL-2.0-only
/*
 * Smoke test for early AxVisor KVM VM/vCPU ABI.
 *
 * Build example:
 *   cc -O2 -Wall -Wextra -o /tmp/axvisor-kvm-mem-vcpu-smoke tools/axvisor-kvm-mem-vcpu-smoke.c
 *
 * Run example:
 *   KVM_DEV=/dev/kvm /tmp/axvisor-kvm-mem-vcpu-smoke
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define GUEST_MEM_SIZE (16UL * 1024UL * 1024UL)

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

#if defined(__x86_64__)
static void exercise_x86_vm_ioctls(int vm_fd)
{
	struct kvm_pit_config pit = { .flags = KVM_PIT_SPEAKER_DUMMY };
	struct kvm_clock_data clock = {};
	struct kvm_irqchip irqchip = { .chip_id = KVM_IRQCHIP_PIC_MASTER };
	struct kvm_pit_state2 pit_state = {};
	struct kvm_ioeventfd ioevent = {};
	struct kvm_irqfd irqfd = {};
	uint64_t identity_map = 0;
	uint64_t irq_signal = 1;
	int event_fd;

	if (ioctl(vm_fd, KVM_SET_TSS_ADDR, 0xfffbd000UL) < 0)
		die_errno("KVM_SET_TSS_ADDR");
	if (ioctl(vm_fd, KVM_SET_IDENTITY_MAP_ADDR, &identity_map) < 0)
		die_errno("KVM_SET_IDENTITY_MAP_ADDR");
	if (ioctl(vm_fd, KVM_CREATE_IRQCHIP, 0) < 0)
		die_errno("KVM_CREATE_IRQCHIP");
	if (ioctl(vm_fd, KVM_CREATE_PIT2, &pit) < 0)
		die_errno("KVM_CREATE_PIT2");
	if (ioctl(vm_fd, KVM_GET_CLOCK, &clock) < 0)
		die_errno("KVM_GET_CLOCK");
	if (ioctl(vm_fd, KVM_SET_CLOCK, &clock) < 0)
		die_errno("KVM_SET_CLOCK");
	if (ioctl(vm_fd, KVM_GET_IRQCHIP, &irqchip) < 0)
		die_errno("KVM_GET_IRQCHIP");
	if (ioctl(vm_fd, KVM_SET_IRQCHIP, &irqchip) < 0)
		die_errno("KVM_SET_IRQCHIP");
	if (ioctl(vm_fd, KVM_GET_PIT2, &pit_state) < 0)
		die_errno("KVM_GET_PIT2");
	if (ioctl(vm_fd, KVM_SET_PIT2, &pit_state) < 0)
		die_errno("KVM_SET_PIT2");

	event_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (event_fd < 0)
		die_errno("eventfd");

	ioevent.fd = event_fd;
	ioevent.addr = 0xd0000000;
	ioevent.len = 4;
	if (ioctl(vm_fd, KVM_IOEVENTFD, &ioevent) < 0)
		die_errno("KVM_IOEVENTFD assign");
	if (ioctl(vm_fd, KVM_IOEVENTFD, &ioevent) != -1 || errno != EEXIST)
		die_msg("KVM_IOEVENTFD duplicate assign did not fail with EEXIST");
	ioevent.flags = KVM_IOEVENTFD_FLAG_DEASSIGN;
	if (ioctl(vm_fd, KVM_IOEVENTFD, &ioevent) < 0)
		die_errno("KVM_IOEVENTFD deassign");

	irqfd.fd = event_fd;
	irqfd.gsi = 5;
	if (ioctl(vm_fd, KVM_IRQFD, &irqfd) < 0)
		die_errno("KVM_IRQFD assign");
	if (write(event_fd, &irq_signal, sizeof(irq_signal)) !=
	    (ssize_t)sizeof(irq_signal))
		die_errno("signal KVM_IRQFD eventfd");
	if (ioctl(vm_fd, KVM_IRQFD, &irqfd) != -1 || errno != EBUSY)
		die_msg("KVM_IRQFD duplicate assign did not fail with EBUSY");
	irqfd.flags = KVM_IRQFD_FLAG_RESAMPLE;
	if (ioctl(vm_fd, KVM_IRQFD, &irqfd) != -1 || errno != EOPNOTSUPP)
		die_msg("KVM_IRQFD resample did not fail with EOPNOTSUPP");
	irqfd.flags = KVM_IRQFD_FLAG_DEASSIGN;
	if (ioctl(vm_fd, KVM_IRQFD, &irqfd) < 0)
		die_errno("KVM_IRQFD deassign");

	close(event_fd);
}

static void exercise_x86_vcpu_ioctls(int vcpu_fd)
{
	struct kvm_regs regs = {};
	struct kvm_sregs sregs = {};
	struct kvm_fpu fpu = {};
	struct kvm_lapic_state lapic = {};
	struct kvm_mp_state mp_state = { .mp_state = KVM_MP_STATE_RUNNABLE };
	struct kvm_debugregs debugregs = {};
	struct kvm_xsave xsave = {};
	struct kvm_xcrs xcrs = {};
	struct kvm_vcpu_events events = {};
	struct {
		struct kvm_cpuid2 cpuid;
		struct kvm_cpuid_entry2 entries[2];
	} cpuid = {};
	struct {
		struct kvm_msrs msrs;
		struct kvm_msr_entry entries[2];
	} msrs = {};
	int ret;

	regs.rip = 0x100000;
	regs.rflags = 0x2;
	if (ioctl(vcpu_fd, KVM_SET_REGS, &regs) < 0)
		die_errno("KVM_SET_REGS");
	memset(&regs, 0, sizeof(regs));
	if (ioctl(vcpu_fd, KVM_GET_REGS, &regs) < 0)
		die_errno("KVM_GET_REGS");
	if (regs.rip != 0x100000)
		die_msg("KVM_GET_REGS did not preserve RIP");

	if (ioctl(vcpu_fd, KVM_SET_SREGS, &sregs) < 0)
		die_errno("KVM_SET_SREGS");
	if (ioctl(vcpu_fd, KVM_GET_SREGS, &sregs) < 0)
		die_errno("KVM_GET_SREGS");
	if (ioctl(vcpu_fd, KVM_SET_FPU, &fpu) < 0)
		die_errno("KVM_SET_FPU");
	if (ioctl(vcpu_fd, KVM_GET_FPU, &fpu) < 0)
		die_errno("KVM_GET_FPU");
	if (ioctl(vcpu_fd, KVM_SET_LAPIC, &lapic) < 0)
		die_errno("KVM_SET_LAPIC");
	if (ioctl(vcpu_fd, KVM_GET_LAPIC, &lapic) < 0)
		die_errno("KVM_GET_LAPIC");
	if (ioctl(vcpu_fd, KVM_SET_MP_STATE, &mp_state) < 0)
		die_errno("KVM_SET_MP_STATE");
	if (ioctl(vcpu_fd, KVM_GET_MP_STATE, &mp_state) < 0)
		die_errno("KVM_GET_MP_STATE");
	if (ioctl(vcpu_fd, KVM_SET_DEBUGREGS, &debugregs) < 0)
		die_errno("KVM_SET_DEBUGREGS");
	if (ioctl(vcpu_fd, KVM_GET_DEBUGREGS, &debugregs) < 0)
		die_errno("KVM_GET_DEBUGREGS");
	if (ioctl(vcpu_fd, KVM_SET_XSAVE, &xsave) < 0)
		die_errno("KVM_SET_XSAVE");
	if (ioctl(vcpu_fd, KVM_GET_XSAVE, &xsave) < 0)
		die_errno("KVM_GET_XSAVE");
	if (ioctl(vcpu_fd, KVM_SET_XCRS, &xcrs) < 0)
		die_errno("KVM_SET_XCRS");
	if (ioctl(vcpu_fd, KVM_GET_XCRS, &xcrs) < 0)
		die_errno("KVM_GET_XCRS");
	if (ioctl(vcpu_fd, KVM_SET_VCPU_EVENTS, &events) < 0)
		die_errno("KVM_SET_VCPU_EVENTS");
	if (ioctl(vcpu_fd, KVM_GET_VCPU_EVENTS, &events) < 0)
		die_errno("KVM_GET_VCPU_EVENTS");
	if (ioctl(vcpu_fd, KVM_SET_TSC_KHZ, 1000000UL) < 0)
		die_errno("KVM_SET_TSC_KHZ");
	ret = ioctl(vcpu_fd, KVM_GET_TSC_KHZ, 0);
	if (ret <= 0)
		die_errno("KVM_GET_TSC_KHZ");

	cpuid.cpuid.nent = 1;
	cpuid.entries[0].function = 0;
	cpuid.entries[0].eax = 1;
	if (ioctl(vcpu_fd, KVM_SET_CPUID2, &cpuid) < 0)
		die_errno("KVM_SET_CPUID2");
	cpuid.cpuid.nent = 2;
	memset(cpuid.entries, 0, sizeof(cpuid.entries));
	if (ioctl(vcpu_fd, KVM_GET_CPUID2, &cpuid) < 0)
		die_errno("KVM_GET_CPUID2");
	if (cpuid.cpuid.nent != 1 || cpuid.entries[0].eax != 1)
		die_msg("KVM_GET_CPUID2 did not preserve CPUID");

	msrs.msrs.nmsrs = 1;
	msrs.entries[0].index = 0x10;
	msrs.entries[0].data = 1234;
	ret = ioctl(vcpu_fd, KVM_SET_MSRS, &msrs);
	if (ret != 1)
		die_errno("KVM_SET_MSRS");
	msrs.entries[0].data = 0;
	ret = ioctl(vcpu_fd, KVM_GET_MSRS, &msrs);
	if (ret != 1)
		die_errno("KVM_GET_MSRS");
	if (msrs.entries[0].data != 1234)
		die_msg("KVM_GET_MSRS did not preserve MSR value");
}
#endif

int main(void)
{
	const char *kvm_dev = getenv("KVM_DEV");
	struct kvm_userspace_memory_region region;
	struct kvm_run *run;
	void *guest_mem;
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

	mmap_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < (int)sizeof(*run))
		die_msg("KVM_GET_VCPU_MMAP_SIZE is too small");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		die_errno("KVM_CREATE_VM");

	guest_mem = mmap(NULL, GUEST_MEM_SIZE, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (guest_mem == MAP_FAILED)
		die_errno("mmap guest memory");

	memset(&region, 0, sizeof(region));
	region.slot = 0;
	region.guest_phys_addr = 0;
	region.memory_size = GUEST_MEM_SIZE;
	region.userspace_addr = (uintptr_t)guest_mem;
	ret = ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region);
	if (ret < 0)
		die_errno("KVM_SET_USER_MEMORY_REGION");

#if defined(__x86_64__)
	exercise_x86_vm_ioctls(vm_fd);
#endif

	vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
	if (vcpu_fd < 0)
		die_errno("KVM_CREATE_VCPU");

#if defined(__x86_64__)
	exercise_x86_vcpu_ioctls(vcpu_fd);
#endif

	run = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		   vcpu_fd, 0);
	if (run == MAP_FAILED)
		die_errno("mmap kvm_run");

	run->immediate_exit = 1;
	ret = ioctl(vcpu_fd, KVM_RUN, 0);
	if (ret != -1 || errno != EINTR)
		die_msg("KVM_RUN immediate_exit did not return EINTR");
	if (run->immediate_exit != 1)
		die_msg("KVM_RUN did not preserve immediate_exit");
	run->immediate_exit = 0;

	ret = ioctl(vcpu_fd, KVM_RUN, 0);
	if (ret < 0)
		die_errno("KVM_RUN");
	if (run->exit_reason != KVM_EXIT_FAIL_ENTRY)
		die_msg("unexpected KVM_RUN exit reason for skeleton provider");

	printf("AXVISOR_KVM_MEM_VCPU_SMOKE_PASS=1\n");
	printf("KVM_DEV=%s\n", kvm_dev);
	printf("KVM_VCPU_MMAP_SIZE=%d\n", mmap_size);
	printf("KVM_RUN_EXIT_REASON=%u\n", run->exit_reason);
	printf("KVM_FAIL_ENTRY_CPU=%u\n", run->fail_entry.cpu);
#if defined(__x86_64__)
	printf("KVM_X86_INIT_IOCTL_SMOKE=1\n");
#endif

	munmap(run, mmap_size);
	close(vcpu_fd);
	munmap(guest_mem, GUEST_MEM_SIZE);
	close(vm_fd);
	close(kvm_fd);
	return 0;
}
