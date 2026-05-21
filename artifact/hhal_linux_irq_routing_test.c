#include "hhal.h"

#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define X86_TSS_ADDR 0xffffd000u
#define TEST_MSI_ADDR UINT64_C(0xfee00000)
#define TEST_MSI_DATA 0x20u

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
    struct hhal_irq_route routes[2];
    struct hhal_irq_routing_table table;
    hhal_vm_t vm = NULL;
    int rc;

    memset(&vm_cfg, 0, sizeof(vm_cfg));
    memset(routes, 0, sizeof(routes));
    memset(&table, 0, sizeof(table));

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

    routes[0].gsi = 0;
    routes[0].type = HHAL_IRQ_ROUTE_IRQCHIP;
    routes[0].u.irqchip.irqchip_id = KVM_IRQCHIP_IOAPIC;
    routes[0].u.irqchip.pin = 0;

    routes[1].gsi = 1;
    routes[1].type = HHAL_IRQ_ROUTE_MSI;
    routes[1].u.msi.address = TEST_MSI_ADDR;
    routes[1].u.msi.data = TEST_MSI_DATA;
    routes[1].u.msi.devid = 0;

    table.num_routes = 2;
    table.routes = routes;

    rc = hhal_vm_set_irq_routing(vm, &table);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_set_irq_routing failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 4;
    }

    printf("IRQCHIP route install succeeded: gsi=0 -> IOAPIC pin 0\n");
    printf("MSI route install succeeded: gsi=1 -> addr=0x%llx data=0x%x\n",
           (unsigned long long)routes[1].u.msi.address,
           routes[1].u.msi.data);

    rc = hhal_vm_irq_line(vm, 0, HHAL_IRQ_ASSERT);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_irq_line assert failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 5;
    }

    rc = hhal_vm_irq_line(vm, 0, HHAL_IRQ_DEASSERT);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_irq_line deassert failed: %s (%d)\n", hhal_status_name(rc), rc);
        hhal_vm_destroy(vm);
        return 6;
    }

    printf("IRQ line assert/deassert succeeded on routed GSI 0\n");

    rc = hhal_vm_destroy(vm);
    if (rc != HHAL_OK) {
        fprintf(stderr, "hhal_vm_destroy failed: %s (%d)\n", hhal_status_name(rc), rc);
        return 7;
    }

    printf("HHAL Linux IRQ routing test completed successfully\n");
    return 0;
}
