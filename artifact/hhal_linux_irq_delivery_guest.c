#define _POSIX_C_SOURCE 200112L

#include "hhal.h"

#include <linux/kvm.h>
#include <pthread.h>
#include <stdint.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GUEST_MEM_SIZE 0x1000u
#define GUEST_PAGE_SIZE 0x1000u
#define X86_TSS_ADDR 0xffffd000u

#define GUEST_ENTRY 0x0100u
#define GUEST_ISR   0x0200u
#define GUEST_FLAG  0x0500u
#define TEST_VECTOR  0x20u

struct irq_thread_args {
    hhal_vcpu_t vcpu;
    int rc;
};

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

static void *irq_thread_main(void *opaque)
{
    struct irq_thread_args *args = (struct irq_thread_args *)opaque;
    struct timespec delay;

    delay.tv_sec = 0;
    delay.tv_nsec = 100 * 1000 * 1000;
    nanosleep(&delay, NULL);

    args->rc = hhal_vcpu_interrupt(args->vcpu, TEST_VECTOR);
    if (args->rc != HHAL_OK) {
        return NULL;
    }
    return NULL;
}

static void patch_real_mode_sregs(struct kvm_sregs *sregs)
{
    sregs->cs.base = 0;
    sregs->cs.selector = 0;
    sregs->ds.base = 0;
    sregs->ds.selector = 0;
    sregs->es.base = 0;
    sregs->es.selector = 0;
    sregs->fs.base = 0;
    sregs->fs.selector = 0;
    sregs->gs.base = 0;
    sregs->gs.selector = 0;
    sregs->ss.base = 0;
    sregs->ss.selector = 0;
}

static void patch_real_mode_regs(struct kvm_regs *regs)
{
    regs->rip = GUEST_ENTRY;
    regs->rflags = 0x2;
    regs->rsp = 0x0700u;
    regs->rbp = 0x0700u;
}

static void install_guest_payload(uint8_t *guest_mem)
{
    /*
     * Main guest payload:
     *   sti
     *   hlt
     *
     * Interrupt handler at vector 0x20:
     *   mov byte ptr [0x0500], 0x42
     *   hlt
     */
    static const uint8_t main_code[] = {
        0xfb, /* sti */
        0xf4, /* hlt */
    };
    static const uint8_t isr_code[] = {
        0xc6, 0x06, 0x00, 0x05, 0x42, /* mov byte ptr [0x0500], 0x42 */
        0xf4,                         /* hlt */
    };

    memcpy(&guest_mem[GUEST_ENTRY], main_code, sizeof(main_code));
    memcpy(&guest_mem[GUEST_ISR], isr_code, sizeof(isr_code));

    /* Real-mode IVT entry for vector 0x20. */
    guest_mem[TEST_VECTOR * 4u + 0] = (uint8_t)(GUEST_ISR & 0xffu);
    guest_mem[TEST_VECTOR * 4u + 1] = (uint8_t)(GUEST_ISR >> 8);
    guest_mem[TEST_VECTOR * 4u + 2] = 0x00;
    guest_mem[TEST_VECTOR * 4u + 3] = 0x00;
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
    struct irq_thread_args irq_args;
    pthread_t irq_thread;
    uint8_t *guest_mem = NULL;
    hhal_vm_t vm = NULL;
    hhal_vcpu_t vcpu = NULL;
    int thread_started = 0;
    int rc;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(&vcpu_cfg, 0, sizeof(vcpu_cfg));
    memset(&region, 0, sizeof(region));
    memset(&state, 0, sizeof(state));
    memset(&run, 0, sizeof(run));
    memset(&regs, 0, sizeof(regs));
    memset(&sregs, 0, sizeof(sregs));
    memset(&irq_args, 0, sizeof(irq_args));

    rc = posix_memalign((void **)&guest_mem, GUEST_PAGE_SIZE, GUEST_MEM_SIZE);
    if (rc != 0) {
        fprintf(stderr, "posix_memalign guest memory failed: %d\n", rc);
        return 1;
    }
    memset(guest_mem, 0, GUEST_MEM_SIZE);
    install_guest_payload(guest_mem);

    vm_cfg.api_version = HHAL_API_VERSION;
    vm_cfg.arch = HHAL_ARCH_X86_64;
    vm_cfg.max_vcpus_hint = 1;

    rc = hhal_vm_create(&vm_cfg, &vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        free(guest_mem);
        return 2;
    }

    rc = hhal_vm_set_tss_addr(vm, X86_TSS_ADDR);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_set_tss_addr failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 3;
    }

    vcpu_cfg.vcpu_id = 0;
    rc = hhal_vcpu_create(vm, &vcpu_cfg, &vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_create failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 4;
    }

    region.slot = 0;
    region.flags = 0;
    region.guest_phys_addr = 0;
    region.memory_size = GUEST_MEM_SIZE;
    region.host_user_addr = (uint64_t)(uintptr_t)guest_mem;
    rc = hhal_vm_map_memory(vm, &region);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_map_memory failed: %s (%d)\n", hhal_status_name(rc), rc);
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
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 6;
    }
    patch_real_mode_sregs(&sregs);
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set sregs failed: %s (%d)\n", hhal_status_name(rc), rc);
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
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 8;
    }
    patch_real_mode_regs(&regs);
    rc = hhal_vcpu_set_state(vcpu, &state);
    if (rc != HHAL_OK) {
        fprintf(stderr, "set regs failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 9;
    }

    irq_args.vcpu = vcpu;
    irq_args.rc = HHAL_OK;
    rc = pthread_create(&irq_thread, NULL, irq_thread_main, &irq_args);
    if (rc != 0) {
        fprintf(stderr, "pthread_create failed: %d\n", rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 10;
    }
    thread_started = 1;

    for (int i = 0; i < 16 && guest_mem[GUEST_FLAG] != 0x42u; ++i) {
        rc = hhal_vcpu_run(vcpu, &run);
        if (rc != HHAL_OK) {
            fprintf(stderr, "hhal_vcpu_run failed: %s (%d)\n", hhal_status_name(rc), rc);
            if (thread_started) {
                pthread_join(irq_thread, NULL);
            }
            hhal_vcpu_destroy(vcpu);
            hhal_vm_destroy(vm);
            free(guest_mem);
            return 11;
        }
        if (run.exit_reason != HHAL_EXIT_HLT) {
            fprintf(stderr, "unexpected exit reason: %u\n", run.exit_reason);
            if (run.exit_reason == HHAL_EXIT_FAIL_ENTRY) {
                fprintf(stderr, "fail_entry.hardware_reason=0x%llx cpu=%llu\n",
                        (unsigned long long)run.u.fail_entry.hardware_reason,
                        (unsigned long long)run.u.fail_entry.cpu);
            }
            if (thread_started) {
                pthread_join(irq_thread, NULL);
            }
            hhal_vcpu_destroy(vcpu);
            hhal_vm_destroy(vm);
            free(guest_mem);
            return 12;
        }
    }

    if (thread_started) {
        pthread_join(irq_thread, NULL);
    }
    if (irq_args.rc != HHAL_OK) {
        fprintf(stderr, "irq thread delivery failed: %s (%d)\n",
                hhal_status_name(irq_args.rc), irq_args.rc);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 13;
    }

    if (guest_mem[GUEST_FLAG] != 0x42u) {
        fprintf(stderr, "interrupt handler did not run, guest flag = 0x%02x\n",
                guest_mem[GUEST_FLAG]);
        hhal_vcpu_destroy(vcpu);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 14;
    }

    printf("Guest interrupt handler executed successfully via routed IRQ0\n");

    rc = hhal_vcpu_destroy(vcpu);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vcpu_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        free(guest_mem);
        return 15;
    }

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        free(guest_mem);
        return 16;
    }

    free(guest_mem);
    return 0;
}
