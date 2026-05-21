#define _POSIX_C_SOURCE 200112L

#include "hhal.h"
#include "hhal_linux_x86_helpers.h"

#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GUEST_MEM_SIZE 0x1000u
#define GUEST_ENTRY    0x0000u
#define GUEST_PAGE_SIZE 0x1000u

static const char *hhal_status_name(int rc)
{
    switch (rc) {
    case HHAL_OK:
        return "HHAL_OK";
    case HHAL_ERR_UNKNOWN:
        return "HHAL_ERR_UNKNOWN";
    case HHAL_ERR_INVALID:
        return "HHAL_ERR_INVALID";
    case HHAL_ERR_NOMEM:
        return "HHAL_ERR_NOMEM";
    case HHAL_ERR_UNSUPPORTED:
        return "HHAL_ERR_UNSUPPORTED";
    case HHAL_ERR_DENIED:
        return "HHAL_ERR_DENIED";
    case HHAL_ERR_BUSY:
        return "HHAL_ERR_BUSY";
    case HHAL_ERR_NOT_FOUND:
        return "HHAL_ERR_NOT_FOUND";
    case HHAL_ERR_STATE:
        return "HHAL_ERR_STATE";
    case HHAL_ERR_IO:
        return "HHAL_ERR_IO";
    case HHAL_ERR_RETRY:
        return "HHAL_ERR_RETRY";
    case HHAL_ERR_EXIT_TO_USER:
        return "HHAL_ERR_EXIT_TO_USER";
    default:
        return "HHAL_STATUS_OTHER";
    }
}

static void patch_real_mode_sregs(struct kvm_sregs *sregs)
{
    sregs->cs.base = 0;
    sregs->cs.selector = 0;
}

static void patch_real_mode_regs(struct kvm_regs *regs)
{
    regs->rip = GUEST_ENTRY;
    regs->rflags = 0x2;
    regs->rsp = 0;
    regs->rbp = 0;
}

int main(void)
{
    struct hhal_vm_config vm_cfg;
    struct hhal_vcpu_config vcpu_cfg;
    struct hhal_mem_region region;
    struct hhal_state_blob state;
    struct hhal_run run;
    struct kvm_regs regs;
    struct kvm_sregs sregs;
    struct kvm_cpuid2 *cpuid = NULL;
    uint8_t *guest_mem = NULL;
    hhal_vm_t vm = NULL;
    hhal_vcpu_t vcpu = NULL;
    int rc = 0;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(&vcpu_cfg, 0, sizeof(vcpu_cfg));
    memset(&region, 0, sizeof(region));
    memset(&state, 0, sizeof(state));
    memset(&run, 0, sizeof(run));

    rc = posix_memalign((void **)&guest_mem, GUEST_PAGE_SIZE, GUEST_MEM_SIZE);
    if (rc != 0) {
        fprintf(stderr, "posix_memalign guest memory failed: %d\n", rc);
        return 1;
    }
    memset(guest_mem, 0, GUEST_MEM_SIZE);

    /*
     * Smallest possible guest payload:
     *   0xf4 = HLT
     * The expected observation is a clean HHAL_EXIT_HLT after one run.
     */
    guest_mem[GUEST_ENTRY] = 0xf4;

    vm_cfg.api_version = HHAL_API_VERSION;
    vm_cfg.arch = HHAL_ARCH_X86_64;
    vm_cfg.max_vcpus_hint = 1;

    rc = hhal_vm_create(&vm_cfg, &vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        free(guest_mem);
        return 2;
    }

    vcpu_cfg.vcpu_id = 0;
    rc = hhal_vcpu_create(vm, &vcpu_cfg, &vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 3;
    }

    cpuid = hhal_linux_cpuid_alloc(128);
    if (cpuid == NULL) {
        fprintf(stderr, "cpuid alloc failed\n");
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 4;
    }

    rc = hhal_linux_get_supported_cpuid(cpuid, hhal_linux_cpuid_bytes(cpuid->nent));
    if (rc == HHAL_OK) {
        state.id = HHAL_VCPU_STATE_CPUID;
        state.data = cpuid;
        state.size = hhal_linux_cpuid_bytes(cpuid->nent);
        rc = hhal_vcpu_set_state(vcpu, &state);
        if (rc != HHAL_OK) {
            fprintf(stderr, "set cpuid failed: %s (%d)\n", hhal_status_name(rc), rc);
            hhal_linux_cpuid_free(cpuid);
            hhal_vcpu_destroy(vcpu);
            hhal_vm_destroy(vm);
            free(guest_mem);
            return 4;
        }
    } else {
        /*
         * In restricted environments, CPUID discovery may fail because /dev/kvm
         * is missing even though the code compiles correctly. The demo tolerates
         * that and falls back to the minimal path.
         */
        fprintf(stderr, "warning: supported cpuid query skipped: %s (%d)\n",
                hhal_status_name(rc), rc);
    }

    region.slot = 0;
    region.flags = 0;
    region.guest_phys_addr = 0;
    region.memory_size = GUEST_MEM_SIZE;
    region.host_user_addr = (uint64_t)(uintptr_t)guest_mem;
    rc = hhal_vm_map_memory(vm, &region);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_map_memory failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 5;
    }

    state.id = HHAL_VCPU_STATE_SREGS;
    state.data = &sregs;
    state.size = sizeof(sregs);
    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get sregs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 6;
    }
    patch_real_mode_sregs(&sregs);
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set sregs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 7;
    }

    state.id = HHAL_VCPU_STATE_REGS;
    state.data = &regs;
    state.size = sizeof(regs);
    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get regs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 8;
    }
    patch_real_mode_regs(&regs);
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set regs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 9;
    }

    rc = hhal_vcpu_run(vcpu, &run);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_run failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 10;
    }

    if (run.exit_reason != HHAL_EXIT_HLT) {
        fprintf(stderr, "unexpected exit reason: %u\n", run.exit_reason);
        if (run.exit_reason == HHAL_EXIT_FAIL_ENTRY) {
            fprintf(stderr, "fail_entry.hardware_reason=0x%llx cpu=%llu\n",
                    (unsigned long long)run.u.fail_entry.hardware_reason,
                    (unsigned long long)run.u.fail_entry.cpu);
        }
        hhal_linux_cpuid_free(cpuid);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 11;
    }

    printf("Minimal HHAL guest reached HLT successfully\n");

    rc = hhal_vcpu_destroy(vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 12;
    }

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_linux_cpuid_free(cpuid);
        free(guest_mem);
        return 13;
    }

    hhal_linux_cpuid_free(cpuid);
    free(guest_mem);
    return 0;
}
