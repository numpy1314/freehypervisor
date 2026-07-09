// SPDX-License-Identifier: GPL-2.0-only
/*
 * Negative KVM ABI smoke test for the AxVisor-backed /dev/kvm frontend.
 *
 * The positive smoke tests prove accepted ioctls can make progress. This file
 * checks the equally important boundary behavior: wrong object class, unknown
 * KVM ioctl, invalid memslot, and duplicate vCPU creation must fail with a
 * defined errno instead of silently succeeding.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define GUEST_MEM_SIZE (4UL * 1024UL * 1024UL)
#define AXVISOR_KVM_UNKNOWN_IOCTL _IO(KVMIO, 0xff)

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

static void expect_errno(const char *name, int ret, int expected)
{
	if (ret != -1) {
		fprintf(stderr, "%s unexpectedly succeeded: ret=%d\n", name,
			ret);
		exit(1);
	}
	if (errno != expected) {
		fprintf(stderr, "%s returned errno=%d (%s), expected errno=%d (%s)\n",
			name, errno, strerror(errno), expected,
			strerror(expected));
		exit(1);
	}
}

int main(void)
{
	const char *kvm_dev = getenv("KVM_DEV");
	struct kvm_userspace_memory_region region = {};
	void *guest_mem;
	int kvm_fd;
	int vm_fd;
	int vcpu_fd;
	int dup_vcpu_fd;
	int ret;

	if (!kvm_dev)
		kvm_dev = "/dev/kvm";

	kvm_fd = open(kvm_dev, O_RDWR | O_CLOEXEC);
	if (kvm_fd < 0)
		die_errno("open KVM device");

	ret = ioctl(kvm_fd, AXVISOR_KVM_UNKNOWN_IOCTL, 0);
	expect_errno("unknown KVM ioctl on kvm fd", ret, ENOTTY);
	printf("NEG_UNKNOWN_IOCTL_ENOTTY=1\n");

	ret = ioctl(kvm_fd, KVM_CREATE_VCPU, 0);
	expect_errno("KVM_CREATE_VCPU on kvm fd", ret, ENOTTY);
	printf("NEG_WRONG_FD_CLASS_KVM_CREATE_VCPU=1\n");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		die_errno("KVM_CREATE_VM");

	ret = ioctl(vm_fd, KVM_GET_API_VERSION, 0);
	expect_errno("KVM_GET_API_VERSION on vm fd", ret, ENOTTY);
	printf("NEG_WRONG_FD_CLASS_VM_GET_API_VERSION=1\n");

	guest_mem = mmap(NULL, GUEST_MEM_SIZE, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (guest_mem == MAP_FAILED)
		die_errno("mmap guest memory");

	region.slot = 0;
	region.guest_phys_addr = 0;
	region.memory_size = 1;
	region.userspace_addr = (uintptr_t)guest_mem;
	ret = ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region);
	expect_errno("unaligned KVM_SET_USER_MEMORY_REGION", ret, EINVAL);
	printf("NEG_BAD_MEMSLOT_EINVAL=1\n");

	vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
	if (vcpu_fd < 0)
		die_errno("KVM_CREATE_VCPU first");

	dup_vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
	expect_errno("duplicate KVM_CREATE_VCPU", dup_vcpu_fd, EEXIST);
	printf("NEG_DUP_VCPU_EEXIST=1\n");

	ret = ioctl(vcpu_fd, KVM_SET_XCRS,
		    &(struct kvm_xcrs){
			    .nr_xcrs = 1,
			    .xcrs = {
				    {
					    .xcr = 0,
					    .value = 0,
				    },
			    },
		    });
	expect_errno("invalid KVM_SET_XCRS", ret, EINVAL);
	printf("NEG_BAD_REGS_XCR0_EINVAL=1\n");

	close(vm_fd);
	ret = ioctl(vcpu_fd, KVM_GET_REGS, &(struct kvm_regs){});
	if (ret < 0)
		die_errno("KVM_GET_REGS after closing vm fd");
	printf("KVM_FD_LIFETIME_VCPU_AFTER_VM_CLOSE=1\n");

	close(vcpu_fd);
	munmap(guest_mem, GUEST_MEM_SIZE);
	close(kvm_fd);

	printf("AXVISOR_KVM_NEGATIVE_SMOKE_PASS=1\n");
	printf("KVM_DEV=%s\n", kvm_dev);
	return 0;
}
