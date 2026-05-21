#include "hhal.h"

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
    uint64_t mask_words[1];
    hhal_vm_t vm = NULL;
    hhal_vcpu_t vcpu = NULL;
    int rc;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(&vcpu_cfg, 0, sizeof(vcpu_cfg));
    memset(&state, 0, sizeof(state));
    memset(mask_words, 0, sizeof(mask_words));

    vm_cfg.api_version = HHAL_API_VERSION;
    vm_cfg.arch = HHAL_ARCH_X86_64;
    vm_cfg.max_vcpus_hint = 1;

    rc = hhal_vm_create(&vm_cfg, &vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 1;
    }

    vcpu_cfg.vcpu_id = 0;
    rc = hhal_vcpu_create(vm, &vcpu_cfg, &vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 2;
    }

    mask_words[0] = (UINT64_C(1) << 2) | (UINT64_C(1) << 10);

    state.id = HHAL_VCPU_STATE_SIGNAL_MASK;
    state.data = mask_words;
    state.size = sizeof(mask_words);

    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set signal mask via state blob failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 3;
    }
    printf("SIGNAL_MASK state write succeeded\n");

    mask_words[0] = UINT64_C(1) << 4;
    rc = hhal_vcpu_signal_mask(vcpu, mask_words, 1);
    if (rc != HHAL_OK) {
        fprintf(stderr, "direct signal mask set failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 4;
    }
    printf("Direct signal mask write succeeded\n");

    rc = hhal_vcpu_destroy(vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 5;
    }

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 6;
    }

    printf("HHAL Linux signal mask test completed successfully\n");
    return 0;
}
