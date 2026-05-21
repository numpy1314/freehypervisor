#include "hhal.h"

#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define X86_TSS_ADDR 0xffffd000u

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

static int roundtrip_state(hhal_vcpu_t vcpu, uint32_t id, void *buf, size_t size, const char *name)
{
    struct hhal_state_blob state;
    int rc;

    memset(&state, 0, sizeof(state));
    state.id = id;
    state.data = buf;
    state.size = size;

    rc = hhal_vcpu_get_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "get %s failed: %s (%d)\n", name, hhal_status_name(rc), rc);
        return rc;
    }

    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set %s failed: %s (%d)\n", name, hhal_status_name(rc), rc);
        return rc;
    }

    printf("%s round-trip succeeded\n", name);
    return HHAL_OK;
}

int main(void)
{
    struct hhal_vm_config vm_cfg;
    struct hhal_vcpu_config vcpu_cfg;
    struct kvm_fpu fpu;
    struct kvm_lapic_state lapic;
    struct kvm_vcpu_events events;
    struct kvm_debugregs debugregs;
    struct kvm_xsave xsave;
    struct kvm_xcrs xcrs;
    hhal_vm_t vm = NULL;
    hhal_vcpu_t vcpu = NULL;
    int rc;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(&vcpu_cfg, 0, sizeof(vcpu_cfg));
    memset(&fpu, 0, sizeof(fpu));
    memset(&lapic, 0, sizeof(lapic));
    memset(&events, 0, sizeof(events));
    memset(&debugregs, 0, sizeof(debugregs));
    memset(&xsave, 0, sizeof(xsave));
    memset(&xcrs, 0, sizeof(xcrs));

    vm_cfg.api_version = HHAL_API_VERSION;
    vm_cfg.arch = HHAL_ARCH_X86_64;
    vm_cfg.max_vcpus_hint = 1;

    rc = hhal_vm_create(&vm_cfg, &vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 1;
    }

    rc = hhal_vm_set_tss_addr(vm, X86_TSS_ADDR);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_set_tss_addr failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 2;
    }

    rc = hhal_vm_create_irqchip(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create_irqchip failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 3;
    }

    vcpu_cfg.vcpu_id = 0;
    rc = hhal_vcpu_create(vm, &vcpu_cfg, &vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 4;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_FPU, &fpu, sizeof(fpu), "FPU");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 5;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_LAPIC, &lapic, sizeof(lapic), "LAPIC");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 6;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_EVENTS, &events, sizeof(events), "EVENTS");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 7;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_DEBUG, &debugregs, sizeof(debugregs), "DEBUG");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 8;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_XSAVE, &xsave, sizeof(xsave), "XSAVE");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 9;
    }

    rc = roundtrip_state(vcpu, HHAL_VCPU_STATE_XCRS, &xcrs, sizeof(xcrs), "XCRS");
    if (rc != HHAL_OK) {
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        return 10;
    }

    rc = hhal_vcpu_destroy(vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 11;
    }

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 12;
    }

    printf("HHAL Linux extended state test completed successfully\n");
    return 0;
}
