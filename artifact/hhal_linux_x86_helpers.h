#ifndef HHAL_LINUX_X86_HELPERS_H
#define HHAL_LINUX_X86_HELPERS_H

#include "hhal.h"

#include <linux/kvm.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

size_t hhal_linux_cpuid_bytes(uint32_t nent);
struct kvm_cpuid2 *hhal_linux_cpuid_alloc(uint32_t nent);
void hhal_linux_cpuid_free(struct kvm_cpuid2 *cpuid);
int hhal_linux_get_supported_cpuid(struct kvm_cpuid2 *cpuid, size_t bytes);

size_t hhal_linux_msrs_bytes(uint32_t nmsrs);
struct kvm_msrs *hhal_linux_msrs_alloc(uint32_t nmsrs);
void hhal_linux_msrs_free(struct kvm_msrs *msrs);

#ifdef __cplusplus
}
#endif

#endif /* HHAL_LINUX_X86_HELPERS_H */
