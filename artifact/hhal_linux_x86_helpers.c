#include "hhal_linux_x86_helpers.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

size_t hhal_linux_cpuid_bytes(uint32_t nent)
{
    return sizeof(struct kvm_cpuid2) +
           ((size_t)nent * sizeof(struct kvm_cpuid_entry2));
}

struct kvm_cpuid2 *hhal_linux_cpuid_alloc(uint32_t nent)
{
    struct kvm_cpuid2 *cpuid;
    size_t bytes = hhal_linux_cpuid_bytes(nent);

    cpuid = calloc(1, bytes);
    if (cpuid == NULL) {
        return NULL;
    }
    cpuid->nent = nent;
    return cpuid;
}

void hhal_linux_cpuid_free(struct kvm_cpuid2 *cpuid)
{
    free(cpuid);
}

int hhal_linux_get_supported_cpuid(struct kvm_cpuid2 *cpuid, size_t bytes)
{
    int fd;
    size_t needed;

    if (cpuid == NULL) {
        return HHAL_ERR_INVALID;
    }

    needed = hhal_linux_cpuid_bytes(cpuid->nent);
    if (bytes < needed) {
        return HHAL_ERR_INVALID;
    }

    fd = open("/dev/kvm", O_RDWR);
    if (fd < 0) {
        switch (errno) {
        case EACCES:
        case EPERM:
            return HHAL_ERR_DENIED;
        case ENOENT:
            return HHAL_ERR_NOT_FOUND;
        default:
            return HHAL_ERR_IO;
        }
    }

    if (ioctl(fd, KVM_GET_SUPPORTED_CPUID, cpuid) < 0) {
        int saved_errno = errno;
        close(fd);
        switch (saved_errno) {
        case E2BIG:
        case EINVAL:
            return HHAL_ERR_INVALID;
        case ENOTTY:
        case EOPNOTSUPP:
        case ENOSYS:
            return HHAL_ERR_UNSUPPORTED;
        default:
            return HHAL_ERR_IO;
        }
    }

    close(fd);
    return HHAL_OK;
}

size_t hhal_linux_msrs_bytes(uint32_t nmsrs)
{
    return sizeof(struct kvm_msrs) +
           ((size_t)nmsrs * sizeof(struct kvm_msr_entry));
}

struct kvm_msrs *hhal_linux_msrs_alloc(uint32_t nmsrs)
{
    struct kvm_msrs *msrs;
    size_t bytes = hhal_linux_msrs_bytes(nmsrs);

    msrs = calloc(1, bytes);
    if (msrs == NULL) {
        return NULL;
    }
    msrs->nmsrs = nmsrs;
    return msrs;
}

void hhal_linux_msrs_free(struct kvm_msrs *msrs)
{
    free(msrs);
}
