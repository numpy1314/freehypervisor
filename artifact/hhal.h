/*
 * hhal.h - Hypervisor Host Abstraction Layer (HHAL)
 *
 * Paper artifact:
 *   This header defines the outer-layer contract between a userspace VMM and
 *   a host-provided hypervisor substrate. It is intentionally architecture-
 *   neutral at the API boundary and does not expose Linux/KVM-specific types.
 *
 * Design scope:
 *   - Portable VMM -> HHAL API
 *   - Opaque VM/VCPU handles
 *   - Core services: VM, VCPU, memory, IRQ, event binding, timer/clock, run-exit
 *   - Extensible state/capability model for architecture-specific details
 *
 * Non-goals in this artifact:
 *   - HHAL -> host-kernel internal primitives
 *   - Backend implementation details
 *   - ABI stability guarantees
 */

#ifndef HHAL_H
#define HHAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HHAL_API_VERSION 0x00010000u

#define HHAL_INVALID_GPA UINT64_C(0xffffffffffffffff)
#define HHAL_INVALID_GVA UINT64_C(0xffffffffffffffff)
#define HHAL_INVALID_HVA UINT64_C(0)

typedef struct hhal_vm *hhal_vm_t;
typedef struct hhal_vcpu *hhal_vcpu_t;

enum hhal_status {
    HHAL_OK = 0,
    HHAL_ERR_UNKNOWN = -1,
    HHAL_ERR_INVALID = -2,
    HHAL_ERR_NOMEM = -3,
    HHAL_ERR_UNSUPPORTED = -4,
    HHAL_ERR_DENIED = -5,
    HHAL_ERR_BUSY = -6,
    HHAL_ERR_NOT_FOUND = -7,
    HHAL_ERR_STATE = -8,
    HHAL_ERR_IO = -9,
    HHAL_ERR_RETRY = -10,
    HHAL_ERR_EXIT_TO_USER = -11,
};

enum hhal_arch {
    HHAL_ARCH_NONE = 0,
    HHAL_ARCH_X86_64 = 1,
    HHAL_ARCH_AARCH64 = 2,
    HHAL_ARCH_RISCV64 = 3,
    HHAL_ARCH_LOONGARCH64 = 4,
};

enum hhal_cap_id {
    HHAL_CAP_MAX_VCPUS = 1,
    HHAL_CAP_MAX_MEMSLOTS = 2,
    HHAL_CAP_DIRTY_LOG = 3,
    HHAL_CAP_READONLY_MEM = 4,
    HHAL_CAP_IOEVENT = 5,
    HHAL_CAP_IRQFD = 6,
    HHAL_CAP_IRQ_ROUTING = 7,
    HHAL_CAP_IRQCHIP = 8,
    HHAL_CAP_PIT = 9,
    HHAL_CAP_CLOCK = 10,
    HHAL_CAP_DEBUG_STATE = 11,
    HHAL_CAP_XSAVE = 12,
    HHAL_CAP_XCRS = 13,
    HHAL_CAP_MP_STATE = 14,
    HHAL_CAP_SIGNAL_MASK = 15,
    HHAL_CAP_GVA_TRANSLATE = 16,
    HHAL_CAP_ARCH_BASE = 0x10000,
};

enum hhal_vm_cap_id {
    HHAL_VM_CAP_SPLIT_IRQCHIP = 1,
    HHAL_VM_CAP_TSC_DEADLINE_TIMER = 2,
    HHAL_VM_CAP_X2APIC_API = 3,
    HHAL_VM_CAP_MANUAL_DIRTY_LOG_PROTECT = 4,
    HHAL_VM_CAP_ARCH_BASE = 0x10000,
};

enum hhal_mem_flags {
    HHAL_MEM_READ = 1u << 0,
    HHAL_MEM_WRITE = 1u << 1,
    HHAL_MEM_EXEC = 1u << 2,
    HHAL_MEM_LOG_DIRTY = 1u << 3,
    HHAL_MEM_READONLY = 1u << 4,
    HHAL_MEM_IO = 1u << 5,
    HHAL_MEM_SHARED = 1u << 6,
    HHAL_MEM_PRIVATE = 1u << 7,
};

enum hhal_irq_route_type {
    HHAL_IRQ_ROUTE_NONE = 0,
    HHAL_IRQ_ROUTE_IRQCHIP = 1,
    HHAL_IRQ_ROUTE_MSI = 2,
};

enum hhal_irq_level {
    HHAL_IRQ_DEASSERT = 0,
    HHAL_IRQ_ASSERT = 1,
    HHAL_IRQ_PULSE = 2,
};

enum hhal_ioevent_flags {
    HHAL_IOEVENT_PIO = 1u << 0,
    HHAL_IOEVENT_MMIO = 1u << 1,
    HHAL_IOEVENT_DATAMATCH = 1u << 2,
    HHAL_IOEVENT_DEASSIGN = 1u << 3,
};

enum hhal_irqfd_flags {
    HHAL_IRQFD_DEASSIGN = 1u << 0,
    HHAL_IRQFD_RESAMPLE = 1u << 1,
};

enum hhal_vcpu_state_id {
    HHAL_VCPU_STATE_REGS = 1,
    HHAL_VCPU_STATE_SREGS = 2,
    HHAL_VCPU_STATE_CPUID = 3,
    HHAL_VCPU_STATE_MSRS = 4,
    HHAL_VCPU_STATE_FPU = 5,
    HHAL_VCPU_STATE_LAPIC = 6,
    HHAL_VCPU_STATE_MP = 7,
    HHAL_VCPU_STATE_EVENTS = 8,
    HHAL_VCPU_STATE_DEBUG = 9,
    HHAL_VCPU_STATE_XSAVE = 10,
    HHAL_VCPU_STATE_XCRS = 11,
    HHAL_VCPU_STATE_SIGNAL_MASK = 12,
    HHAL_VCPU_STATE_ARCH_BASE = 0x10000,
};

enum hhal_exit_reason {
    HHAL_EXIT_NONE = 0,
    HHAL_EXIT_IO = 1,
    HHAL_EXIT_MMIO = 2,
    HHAL_EXIT_INTR = 3,
    HHAL_EXIT_HLT = 4,
    HHAL_EXIT_SHUTDOWN = 5,
    HHAL_EXIT_SYSTEM_EVENT = 6,
    HHAL_EXIT_FAIL_ENTRY = 7,
    HHAL_EXIT_INTERNAL_ERROR = 8,
    HHAL_EXIT_HYPERCALL = 9,
    HHAL_EXIT_DEBUG = 10,
    HHAL_EXIT_SIGNAL = 11,
    HHAL_EXIT_UNKNOWN = 0xffffffffu,
};

enum hhal_io_dir {
    HHAL_IO_IN = 0,
    HHAL_IO_OUT = 1,
};

struct hhal_capability {
    uint32_t id;
    uint32_t flags;
    uint64_t value;
};

struct hhal_vm_config {
    uint32_t api_version;
    uint32_t arch;
    uint32_t max_vcpus_hint;
    uint32_t reserved0;
    uint64_t user_opaque;
};

struct hhal_vcpu_config {
    uint32_t vcpu_id;
    uint32_t flags;
    uint64_t entry_arg;
};

struct hhal_mem_region {
    uint32_t slot;
    uint32_t flags;
    uint64_t guest_phys_addr;
    uint64_t memory_size;
    uint64_t host_user_addr;
};

struct hhal_dirty_log {
    uint32_t slot;
    uint32_t flags;
    uint64_t first_page;
    uint64_t num_pages;
    void *bitmap;
    size_t bitmap_size;
};

struct hhal_gva_translation {
    uint64_t gva;
    uint64_t gpa;
    uint32_t flags;
    uint32_t reserved0;
};

struct hhal_irq_line_status {
    uint32_t gsi;
    uint32_t level;
    uint32_t status;
    uint32_t reserved0;
};

struct hhal_irq_routing_irqchip {
    uint32_t irqchip_id;
    uint32_t pin;
};

struct hhal_irq_routing_msi {
    uint64_t address;
    uint32_t data;
    uint32_t devid;
};

struct hhal_irq_route {
    uint32_t gsi;
    uint32_t type;
    union {
        struct hhal_irq_routing_irqchip irqchip;
        struct hhal_irq_routing_msi msi;
    } u;
};

struct hhal_irq_routing_table {
    uint32_t num_routes;
    uint32_t flags;
    struct hhal_irq_route *routes;
};

struct hhal_ioevent {
    int fd;
    uint32_t flags;
    uint16_t len;
    uint16_t reserved0;
    uint64_t addr;
    uint64_t data;
};

struct hhal_irqfd {
    int fd;
    int resample_fd;
    uint32_t gsi;
    uint32_t flags;
};

struct hhal_clock_data {
    uint64_t value_ns;
    uint64_t flags;
};

struct hhal_pit_config {
    uint32_t flags;
    uint32_t reserved0;
};

struct hhal_io_exit {
    uint16_t port;
    uint8_t size;
    uint8_t count;
    uint8_t direction;
    uint8_t data[8];
};

struct hhal_mmio_exit {
    uint64_t addr;
    uint32_t len;
    uint8_t is_write;
    uint8_t data[8];
};

struct hhal_system_event_exit {
    uint32_t type;
    uint32_t flags;
};

struct hhal_fail_entry_exit {
    uint64_t hardware_reason;
    uint64_t cpu;
};

struct hhal_internal_error_exit {
    uint32_t suberror;
    uint32_t ndata;
    uint64_t data[8];
};

struct hhal_hypercall_exit {
    uint64_t nr;
    uint64_t args[6];
    uint64_t ret;
};

struct hhal_run {
    uint32_t exit_reason;
    uint32_t flags;
    union {
        struct hhal_io_exit io;
        struct hhal_mmio_exit mmio;
        struct hhal_system_event_exit system_event;
        struct hhal_fail_entry_exit fail_entry;
        struct hhal_internal_error_exit internal_error;
        struct hhal_hypercall_exit hypercall;
    } u;
};

struct hhal_state_blob {
    uint32_t id;
    uint32_t flags;
    void *data;
    size_t size;
};

int hhal_get_api_version(uint32_t *version);
int hhal_query_capability(struct hhal_capability *cap);

int hhal_vm_create(const struct hhal_vm_config *cfg, hhal_vm_t *out_vm);
int hhal_vm_destroy(hhal_vm_t vm);
int hhal_vm_enable_cap(hhal_vm_t vm, uint32_t cap_id, uint64_t arg0, uint64_t arg1);

int hhal_vm_set_tss_addr(hhal_vm_t vm, uint64_t guest_phys_addr);
int hhal_vm_set_identity_map_addr(hhal_vm_t vm, uint64_t guest_phys_addr);

int hhal_vm_map_memory(hhal_vm_t vm, const struct hhal_mem_region *region);
int hhal_vm_unmap_memory(hhal_vm_t vm, uint32_t slot);
int hhal_vm_get_dirty_log(hhal_vm_t vm, struct hhal_dirty_log *log);
int hhal_vm_clear_dirty_log(hhal_vm_t vm, const struct hhal_dirty_log *log);

int hhal_vm_create_irqchip(hhal_vm_t vm);
int hhal_vm_set_irq_routing(hhal_vm_t vm, const struct hhal_irq_routing_table *table);
int hhal_vm_irq_line(hhal_vm_t vm, uint32_t gsi, uint32_t level);
int hhal_vm_irq_line_status(hhal_vm_t vm, struct hhal_irq_line_status *irq);
int hhal_vm_bind_irqfd(hhal_vm_t vm, const struct hhal_irqfd *irqfd);
int hhal_vm_bind_ioevent(hhal_vm_t vm, const struct hhal_ioevent *ioevent);

int hhal_vm_create_pit(hhal_vm_t vm, const struct hhal_pit_config *cfg);
int hhal_vm_get_clock(hhal_vm_t vm, struct hhal_clock_data *clock);
int hhal_vm_set_clock(hhal_vm_t vm, const struct hhal_clock_data *clock);

int hhal_vcpu_create(hhal_vm_t vm, const struct hhal_vcpu_config *cfg, hhal_vcpu_t *out_vcpu);
int hhal_vcpu_destroy(hhal_vcpu_t vcpu);
int hhal_vcpu_run(hhal_vcpu_t vcpu, struct hhal_run *run);
int hhal_vcpu_translate_gva(hhal_vcpu_t vcpu, struct hhal_gva_translation *translation);

int hhal_vcpu_get_state(hhal_vcpu_t vcpu, struct hhal_state_blob *state);
int hhal_vcpu_set_state(hhal_vcpu_t vcpu, const struct hhal_state_blob *state);

int hhal_vcpu_interrupt(hhal_vcpu_t vcpu, uint32_t vector);
int hhal_vcpu_nmi(hhal_vcpu_t vcpu);
int hhal_vcpu_signal_mask(hhal_vcpu_t vcpu, const uint64_t *mask_words, size_t num_words);

#ifdef __cplusplus
}
#endif

#endif /* HHAL_H */
