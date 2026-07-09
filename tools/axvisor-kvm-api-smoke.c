// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal userspace smoke test for the AxVisor KVM ABI provider.
 *
 * Build example:
 *   cc -O2 -Wall -Wextra -o /tmp/axvisor-kvm-api-smoke tools/axvisor-kvm-api-smoke.c
 *
 * Run example:
 *   KVM_DEV=/dev/kvm /tmp/axvisor-kvm-api-smoke
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define AXVISOR_KVM_API_SMOKE_CPUID_ENTRIES 256
#define AXVISOR_KVM_API_SMOKE_MSR_ENTRIES 512

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

int main(void)
{
	const char *kvm_dev = getenv("KVM_DEV");
#if defined(__x86_64__)
	struct {
		struct kvm_cpuid2 cpuid;
		struct kvm_cpuid_entry2 entries[AXVISOR_KVM_API_SMOKE_CPUID_ENTRIES];
	} cpuid = {};
	struct {
		struct kvm_msr_list list;
		uint32_t indices[AXVISOR_KVM_API_SMOKE_MSR_ENTRIES];
	} msrs = {};
#endif
	int kvm_fd;
	int vm_fd;
	int api_version;
	int mmap_size;
	int cap_user_memory;
	int cap_memslots;

	if (!kvm_dev)
		kvm_dev = "/dev/kvm";

	kvm_fd = open(kvm_dev, O_RDWR | O_CLOEXEC);
	if (kvm_fd < 0)
		die_errno("open KVM device");

	api_version = ioctl(kvm_fd, KVM_GET_API_VERSION, 0);
	if (api_version < 0)
		die_errno("KVM_GET_API_VERSION");
	if (api_version != KVM_API_VERSION)
		die_msg("unexpected KVM API version");

	cap_user_memory = ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_USER_MEMORY);
	if (cap_user_memory <= 0)
		die_msg("KVM_CAP_USER_MEMORY is not available");

	cap_memslots = ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_NR_MEMSLOTS);
	if (cap_memslots <= 0)
		die_msg("KVM_CAP_NR_MEMSLOTS is not available");

#if defined(__x86_64__)
	if (ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_IRQCHIP) <= 0)
		die_msg("KVM_CAP_IRQCHIP is not available");
	if (ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_IOEVENTFD) <= 0)
		die_msg("KVM_CAP_IOEVENTFD is not available");
	if (ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_IRQFD) <= 0)
		die_msg("KVM_CAP_IRQFD is not available");
	if (ioctl(kvm_fd, KVM_CHECK_EXTENSION, KVM_CAP_EXT_CPUID) <= 0)
		die_msg("KVM_CAP_EXT_CPUID is not available");

	cpuid.cpuid.nent = AXVISOR_KVM_API_SMOKE_CPUID_ENTRIES;
	if (ioctl(kvm_fd, KVM_GET_SUPPORTED_CPUID, &cpuid) < 0)
		die_errno("KVM_GET_SUPPORTED_CPUID");
	if (!cpuid.cpuid.nent)
		die_msg("KVM_GET_SUPPORTED_CPUID returned no entries");

	msrs.list.nmsrs = AXVISOR_KVM_API_SMOKE_MSR_ENTRIES;
	if (ioctl(kvm_fd, KVM_GET_MSR_INDEX_LIST, &msrs) < 0)
		die_errno("KVM_GET_MSR_INDEX_LIST");
	if (!msrs.list.nmsrs)
		die_msg("KVM_GET_MSR_INDEX_LIST returned no entries");
#endif

	mmap_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < (int)sizeof(struct kvm_run))
		die_msg("KVM_GET_VCPU_MMAP_SIZE is too small");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		die_errno("KVM_CREATE_VM");

	printf("AXVISOR_KVM_API_SMOKE_PASS=1\n");
	printf("KVM_DEV=%s\n", kvm_dev);
	printf("KVM_API_VERSION=%d\n", api_version);
	printf("KVM_CAP_USER_MEMORY=%d\n", cap_user_memory);
	printf("KVM_CAP_NR_MEMSLOTS=%d\n", cap_memslots);
	printf("KVM_VCPU_MMAP_SIZE=%d\n", mmap_size);
#if defined(__x86_64__)
	printf("KVM_SUPPORTED_CPUID_NENT=%u\n", cpuid.cpuid.nent);
	printf("KVM_MSR_INDEX_COUNT=%u\n", msrs.list.nmsrs);
#endif

	close(vm_fd);
	close(kvm_fd);
	return 0;
}
