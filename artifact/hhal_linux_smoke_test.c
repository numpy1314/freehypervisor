#include "hhal.h"

#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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

int main(void)
{
    struct hhal_vm_config vm_cfg;
    struct hhal_vcpu_config vcpu_cfg;
    struct hhal_state_blob state;
    struct kvm_regs regs;
    struct kvm_sregs sregs;
    struct kvm_mp_state mp;
    hhal_vm_t vm = NULL;
    hhal_vcpu_t vcpu = NULL;
    uint32_t api_version = 0;
    int rc;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(&vcpu_cfg, 0, sizeof(vcpu_cfg));
    memset(&state, 0, sizeof(state));
    memset(&regs, 0, sizeof(regs));
    memset(&sregs, 0, sizeof(sregs));
    memset(&mp, 0, sizeof(mp));

    rc = hhal_get_api_version(&api_version);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_get_api_version failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 1;
    }
    printf("HHAL API version query succeeded: %u\n", api_version);

    vm_cfg.api_version = HHAL_API_VERSION;
    vm_cfg.arch = HHAL_ARCH_X86_64;
    vm_cfg.max_vcpus_hint = 1;

    rc = hhal_vm_create(&vm_cfg, &vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 2;
    }
    printf("VM create succeeded\n");

    vcpu_cfg.vcpu_id = 0;
    rc = hhal_vcpu_create(vm, &vcpu_cfg, &vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 3;
    }
    printf("VCPU create succeeded\n");

    state.id = HHAL_VCPU_STATE_REGS;
    state.data = &regs;
    state.size = sizeof(regs);
    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get regs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 4;
    }
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set regs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 5;
    }
    printf("REGS round-trip succeeded\n");

    state.id = HHAL_VCPU_STATE_SREGS;
    state.data = &sregs;
    state.size = sizeof(sregs);
    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get sregs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 6;
    }
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set sregs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 7;
    }
    printf("SREGS round-trip succeeded\n");

    state.id = HHAL_VCPU_STATE_MP;
    state.data = &mp;
    state.size = sizeof(mp);
    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get mp state failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 8;
    }
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set mp state failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 9;
    }
    printf("MP state round-trip succeeded\n");

    rc = hhal_vcpu_destroy(vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 10;
    }

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 11;
    }

    printf("HHAL Linux smoke test completed successfully\n");
    return 0;
}
