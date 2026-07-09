// SPDX-License-Identifier: GPL-2.0-only
/*
 * Smoke test for two concurrent KVM_RUN callers.
 *
 * The test does not require a fully bootable guest. It verifies that two vCPU
 * fds can be driven by two host threads at the same time and that each KVM_RUN
 * returns a deterministic KVM exit instead of deadlocking.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define GUEST_MEM_SIZE (16UL * 1024UL * 1024UL)
#define VCPU_ENTRY_BASE 0x100000UL
#define VCPU_ENTRY_STRIDE 0x1000UL
#define VCPU_COUNT 2

struct vcpu_thread_arg {
	int vcpu_id;
	int vcpu_fd;
	int mmap_size;
	pthread_barrier_t *barrier;
	int ret;
	int err;
	uint32_t exit_reason;
};

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

static void setup_x86_vcpu(int vcpu_fd, int vcpu_id)
{
#if defined(__x86_64__)
	struct kvm_regs regs = {
		.rip = 0x100000 + (uint64_t)vcpu_id * 0x1000,
		.rflags = 0x2,
	};
	struct kvm_sregs sregs = {};
	struct kvm_fpu fpu = {
		.fcw = 0x37f,
		.mxcsr = 0x1f80,
	};
	struct kvm_lapic_state lapic = {};
	struct kvm_mp_state mp_state = { .mp_state = KVM_MP_STATE_RUNNABLE };
	struct {
		struct kvm_cpuid2 cpuid;
		struct kvm_cpuid_entry2 entries[1];
	} cpuid = {};

	if (ioctl(vcpu_fd, KVM_SET_REGS, &regs) < 0)
		die_errno("KVM_SET_REGS");
	if (ioctl(vcpu_fd, KVM_SET_SREGS, &sregs) < 0)
		die_errno("KVM_SET_SREGS");
	if (ioctl(vcpu_fd, KVM_SET_FPU, &fpu) < 0)
		die_errno("KVM_SET_FPU");
	lapic.regs[0x23] = (uint8_t)vcpu_id;
	if (ioctl(vcpu_fd, KVM_SET_LAPIC, &lapic) < 0)
		die_errno("KVM_SET_LAPIC");
	if (ioctl(vcpu_fd, KVM_SET_MP_STATE, &mp_state) < 0)
		die_errno("KVM_SET_MP_STATE");

	cpuid.cpuid.nent = 1;
	cpuid.entries[0].function = 0;
	cpuid.entries[0].eax = 1;
	if (ioctl(vcpu_fd, KVM_SET_CPUID2, &cpuid) < 0)
		die_errno("KVM_SET_CPUID2");
#else
	(void)vcpu_fd;
	(void)vcpu_id;
#endif
}

static void *vcpu_thread_main(void *opaque)
{
	struct vcpu_thread_arg *arg = opaque;
	struct kvm_run *run;
	int ret;

	run = mmap(NULL, arg->mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		   arg->vcpu_fd, 0);
	if (run == MAP_FAILED) {
		arg->ret = -1;
		arg->err = errno;
		return NULL;
	}

	pthread_barrier_wait(arg->barrier);
	ret = ioctl(arg->vcpu_fd, KVM_RUN, 0);
	arg->ret = ret;
	arg->err = ret < 0 ? errno : 0;
	arg->exit_reason = run->exit_reason;

	munmap(run, arg->mmap_size);
	return NULL;
}

int main(void)
{
	const char *kvm_dev = getenv("KVM_DEV");
	struct kvm_userspace_memory_region region = {};
	pthread_barrier_t barrier;
	pthread_t threads[VCPU_COUNT];
	struct vcpu_thread_arg args[VCPU_COUNT];
	void *guest_mem;
	int kvm_fd;
	int vm_fd;
	int mmap_size;
	int vcpu_fds[VCPU_COUNT];
	int i;

	if (!kvm_dev)
		kvm_dev = "/dev/kvm";

	kvm_fd = open(kvm_dev, O_RDWR | O_CLOEXEC);
	if (kvm_fd < 0)
		die_errno("open KVM device");

	mmap_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < (int)sizeof(struct kvm_run))
		die_msg("KVM_GET_VCPU_MMAP_SIZE is too small");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		die_errno("KVM_CREATE_VM");

	guest_mem = mmap(NULL, GUEST_MEM_SIZE, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (guest_mem == MAP_FAILED)
		die_errno("mmap guest memory");
	for (i = 0; i < VCPU_COUNT; i++)
		((uint8_t *)guest_mem)[VCPU_ENTRY_BASE + i * VCPU_ENTRY_STRIDE] = 0xf4;

	region.slot = 0;
	region.guest_phys_addr = 0;
	region.memory_size = GUEST_MEM_SIZE;
	region.userspace_addr = (uintptr_t)guest_mem;
	if (ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region) < 0)
		die_errno("KVM_SET_USER_MEMORY_REGION");

#if defined(__x86_64__)
	{
		struct kvm_pit_config pit = { .flags = KVM_PIT_SPEAKER_DUMMY };
		uint64_t identity_map = 0;

		if (ioctl(vm_fd, KVM_SET_TSS_ADDR, 0xfffbd000UL) < 0)
			die_errno("KVM_SET_TSS_ADDR");
		if (ioctl(vm_fd, KVM_SET_IDENTITY_MAP_ADDR, &identity_map) < 0)
			die_errno("KVM_SET_IDENTITY_MAP_ADDR");
		if (ioctl(vm_fd, KVM_CREATE_IRQCHIP, 0) < 0)
			die_errno("KVM_CREATE_IRQCHIP");
		if (ioctl(vm_fd, KVM_CREATE_PIT2, &pit) < 0)
			die_errno("KVM_CREATE_PIT2");
	}
#endif

	for (i = 0; i < VCPU_COUNT; i++) {
		vcpu_fds[i] = ioctl(vm_fd, KVM_CREATE_VCPU, i);
		if (vcpu_fds[i] < 0)
			die_errno("KVM_CREATE_VCPU");
		setup_x86_vcpu(vcpu_fds[i], i);
	}

	if (pthread_barrier_init(&barrier, NULL, VCPU_COUNT))
		die_errno("pthread_barrier_init");

	for (i = 0; i < VCPU_COUNT; i++) {
		memset(&args[i], 0, sizeof(args[i]));
		args[i].vcpu_id = i;
		args[i].vcpu_fd = vcpu_fds[i];
		args[i].mmap_size = mmap_size;
		args[i].barrier = &barrier;
		if (pthread_create(&threads[i], NULL, vcpu_thread_main, &args[i]))
			die_errno("pthread_create");
	}

	for (i = 0; i < VCPU_COUNT; i++) {
		if (pthread_join(threads[i], NULL))
			die_errno("pthread_join");
		if (args[i].ret < 0)
			die_msg("concurrent KVM_RUN returned error");
		if (args[i].exit_reason != KVM_EXIT_FAIL_ENTRY &&
		    args[i].exit_reason != KVM_EXIT_INTERNAL_ERROR &&
		    args[i].exit_reason != KVM_EXIT_HLT &&
		    args[i].exit_reason != KVM_EXIT_MMIO &&
		    args[i].exit_reason != KVM_EXIT_IO)
			die_msg("concurrent KVM_RUN returned unexpected exit");
	}

	printf("AXVISOR_KVM_CONCURRENT_RUN_SMOKE_PASS=1\n");
	printf("KVM_DEV=%s\n", kvm_dev);
	for (i = 0; i < VCPU_COUNT; i++)
		printf("VCPU%d_EXIT_REASON=%u\n", i, args[i].exit_reason);

	pthread_barrier_destroy(&barrier);
	for (i = 0; i < VCPU_COUNT; i++)
		close(vcpu_fds[i]);
	munmap(guest_mem, GUEST_MEM_SIZE);
	close(vm_fd);
	close(kvm_fd);
	return 0;
}
