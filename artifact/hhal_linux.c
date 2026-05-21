#include "hhal.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

struct hhal_vm {
    int sys_fd;
    int vm_fd;
    uint32_t arch;
};

struct hhal_vcpu {
    struct hhal_vm *vm;
    int vcpu_fd;
    uint32_t vcpu_id;
    size_t run_mmap_size;
    struct kvm_run *run;
};

static int hhal_linux_error(int err)
{
    switch (err) {
    case 0:
        return HHAL_OK;
    case EINVAL:
        return HHAL_ERR_INVALID;
    case ENOMEM:
        return HHAL_ERR_NOMEM;
    case ENOENT:
        return HHAL_ERR_NOT_FOUND;
    case EEXIST:
    case EBUSY:
        return HHAL_ERR_BUSY;
    case EPERM:
    case EACCES:
        return HHAL_ERR_DENIED;
    case ENOTTY:
    case EOPNOTSUPP:
    case ENOSYS:
        return HHAL_ERR_UNSUPPORTED;
    case EAGAIN:
    case EINTR:
        return HHAL_ERR_RETRY;
    default:
        return HHAL_ERR_IO;
    }
}

static int hhal_open_kvm(void)
{
    return open("/dev/kvm", O_RDWR);
}

static void hhal_close_fd(int *fd)
{
    if (fd != NULL && *fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

static void hhal_zero_run(struct hhal_run *run)
{
    if (run != NULL) {
        memset(run, 0, sizeof(*run));
        run->exit_reason = HHAL_EXIT_NONE;
    }
}

static int hhal_require(bool cond)
{
    return cond ? HHAL_OK : HHAL_ERR_INVALID;
}

static int hhal_check_vm(hhal_vm_t vm)
{
    return hhal_require(vm != NULL && vm->sys_fd >= 0 && vm->vm_fd >= 0);
}

static int hhal_check_vcpu(hhal_vcpu_t vcpu)
{
    return hhal_require(vcpu != NULL && vcpu->vm != NULL && vcpu->vcpu_fd >= 0);
}

static int hhal_require_state_blob(struct hhal_state_blob *state, uint32_t id, size_t min_size)
{
    if (state == NULL || state->id != id || state->data == NULL) {
        return HHAL_ERR_INVALID;
    }
    if (state->size < min_size) {
        state->size = min_size;
        return HHAL_ERR_INVALID;
    }
    return HHAL_OK;
}

static int hhal_require_const_state_blob(const struct hhal_state_blob *state, uint32_t id, size_t min_size)
{
    if (state == NULL || state->id != id || state->data == NULL) {
        return HHAL_ERR_INVALID;
    }
    if (state->size < min_size) {
        return HHAL_ERR_INVALID;
    }
    return HHAL_OK;
}

static size_t hhal_kvm_cpuid_min_size(const struct hhal_state_blob *state)
{
    const struct kvm_cpuid2 *cpuid;

    if (state == NULL || state->data == NULL || state->size < sizeof(struct kvm_cpuid2)) {
        return sizeof(struct kvm_cpuid2);
    }

    cpuid = (const struct kvm_cpuid2 *)state->data;
    return sizeof(struct kvm_cpuid2) +
           ((size_t)cpuid->nent * sizeof(struct kvm_cpuid_entry2));
}

static size_t hhal_kvm_msrs_min_size(const struct hhal_state_blob *state)
{
    const struct kvm_msrs *msrs;

    if (state == NULL || state->data == NULL || state->size < sizeof(struct kvm_msrs)) {
        return sizeof(struct kvm_msrs);
    }

    msrs = (const struct kvm_msrs *)state->data;
    return sizeof(struct kvm_msrs) +
           ((size_t)msrs->nmsrs * sizeof(struct kvm_msr_entry));
}

static void hhal_fill_io_exit(struct hhal_run *out, const struct kvm_run *in)
{
    out->exit_reason = HHAL_EXIT_IO;
    out->u.io.port = in->io.port;
    out->u.io.size = in->io.size;
    out->u.io.count = (uint8_t)in->io.count;
    out->u.io.direction = (uint8_t)in->io.direction;

    if (in->io.size > 0 && in->io.size <= sizeof(out->u.io.data) &&
        in->io.count == 1 && in->io.data_offset > 0) {
        const uint8_t *src = ((const uint8_t *)in) + in->io.data_offset;
        memcpy(out->u.io.data, src, in->io.size);
    }
}

static void hhal_fill_mmio_exit(struct hhal_run *out, const struct kvm_run *in)
{
    out->exit_reason = HHAL_EXIT_MMIO;
    out->u.mmio.addr = in->mmio.phys_addr;
    out->u.mmio.len = in->mmio.len;
    out->u.mmio.is_write = in->mmio.is_write;
    memcpy(out->u.mmio.data, in->mmio.data, sizeof(out->u.mmio.data));
}

static void hhal_fill_system_event_exit(struct hhal_run *out, const struct kvm_run *in)
{
    out->exit_reason = HHAL_EXIT_SYSTEM_EVENT;
    out->u.system_event.type = in->system_event.type;
    out->u.system_event.flags = in->system_event.flags;
}

static void hhal_fill_fail_entry_exit(struct hhal_run *out, const struct kvm_run *in)
{
    out->exit_reason = HHAL_EXIT_FAIL_ENTRY;
    out->u.fail_entry.hardware_reason = in->fail_entry.hardware_entry_failure_reason;
    out->u.fail_entry.cpu = in->fail_entry.cpu;
}

static void hhal_fill_internal_error_exit(struct hhal_run *out, const struct kvm_run *in)
{
    uint32_t ndata;

    out->exit_reason = HHAL_EXIT_INTERNAL_ERROR;
    out->u.internal_error.suberror = in->internal.suberror;
    ndata = in->internal.ndata;
    if (ndata > 8u) {
        ndata = 8u;
    }
    out->u.internal_error.ndata = ndata;
    for (uint32_t i = 0; i < ndata; ++i) {
        out->u.internal_error.data[i] = in->internal.data[i];
    }
}

static void hhal_translate_run_exit(struct hhal_run *out, const struct kvm_run *in)
{
    hhal_zero_run(out);

    switch (in->exit_reason) {
    case KVM_EXIT_IO:
        hhal_fill_io_exit(out, in);
        break;
    case KVM_EXIT_MMIO:
        hhal_fill_mmio_exit(out, in);
        break;
    case KVM_EXIT_INTR:
        out->exit_reason = HHAL_EXIT_INTR;
        break;
    case KVM_EXIT_HLT:
        out->exit_reason = HHAL_EXIT_HLT;
        break;
    case KVM_EXIT_SHUTDOWN:
        out->exit_reason = HHAL_EXIT_SHUTDOWN;
        break;
    case KVM_EXIT_SYSTEM_EVENT:
        hhal_fill_system_event_exit(out, in);
        break;
    case KVM_EXIT_FAIL_ENTRY:
        hhal_fill_fail_entry_exit(out, in);
        break;
    case KVM_EXIT_INTERNAL_ERROR:
        hhal_fill_internal_error_exit(out, in);
        break;
    case KVM_EXIT_DEBUG:
        out->exit_reason = HHAL_EXIT_DEBUG;
        break;
#ifdef KVM_EXIT_HYPERCALL
    case KVM_EXIT_HYPERCALL:
        out->exit_reason = HHAL_EXIT_HYPERCALL;
        break;
#endif
    default:
        out->exit_reason = HHAL_EXIT_UNKNOWN;
        out->flags = in->exit_reason;
        break;
    }
}

int hhal_get_api_version(uint32_t *version)
{
    int fd;
    int ret;

    if (version == NULL) {
        return HHAL_ERR_INVALID;
    }

    fd = hhal_open_kvm();
    if (fd < 0) {
        return hhal_linux_error(errno);
    }

    ret = ioctl(fd, KVM_GET_API_VERSION, 0);
    if (ret < 0) {
        hhal_close_fd(&fd);
        return hhal_linux_error(errno);
    }

    *version = (uint32_t)ret;
    hhal_close_fd(&fd);
    return HHAL_OK;
}

int hhal_query_capability(struct hhal_capability *cap)
{
    int fd;
    int ret;

    if (cap == NULL) {
        return HHAL_ERR_INVALID;
    }

    fd = hhal_open_kvm();
    if (fd < 0) {
        return hhal_linux_error(errno);
    }

    ret = ioctl(fd, KVM_CHECK_EXTENSION, (unsigned long)cap->id);
    if (ret < 0) {
        hhal_close_fd(&fd);
        return hhal_linux_error(errno);
    }

    cap->value = (uint64_t)ret;
    hhal_close_fd(&fd);
    return HHAL_OK;
}

int hhal_vm_create(const struct hhal_vm_config *cfg, hhal_vm_t *out_vm)
{
    struct hhal_vm *vm;
    int sys_fd;
    int vm_fd;

    if (cfg == NULL || out_vm == NULL) {
        return HHAL_ERR_INVALID;
    }
    if (cfg->api_version != HHAL_API_VERSION) {
        return HHAL_ERR_INVALID;
    }

    sys_fd = hhal_open_kvm();
    if (sys_fd < 0) {
        return hhal_linux_error(errno);
    }

    vm_fd = ioctl(sys_fd, KVM_CREATE_VM, 0);
    if (vm_fd < 0) {
        hhal_close_fd(&sys_fd);
        return hhal_linux_error(errno);
    }

    vm = calloc(1, sizeof(*vm));
    if (vm == NULL) {
        hhal_close_fd(&vm_fd);
        hhal_close_fd(&sys_fd);
        return HHAL_ERR_NOMEM;
    }

    vm->sys_fd = sys_fd;
    vm->vm_fd = vm_fd;
    vm->arch = cfg->arch;
    *out_vm = vm;
    return HHAL_OK;
}

int hhal_vm_destroy(hhal_vm_t vm)
{
    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    hhal_close_fd(&vm->vm_fd);
    hhal_close_fd(&vm->sys_fd);
    free(vm);
    return HHAL_OK;
}

int hhal_vm_enable_cap(hhal_vm_t vm, uint32_t cap_id, uint64_t arg0, uint64_t arg1)
{
    struct kvm_enable_cap cap = {0};

    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    cap.cap = cap_id;
    cap.args[0] = arg0;
    cap.args[1] = arg1;
    if (ioctl(vm->vm_fd, KVM_ENABLE_CAP, &cap) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_set_tss_addr(hhal_vm_t vm, uint64_t guest_phys_addr)
{
    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }
    if (ioctl(vm->vm_fd, KVM_SET_TSS_ADDR, guest_phys_addr) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_set_identity_map_addr(hhal_vm_t vm, uint64_t guest_phys_addr)
{
    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }
    if (ioctl(vm->vm_fd, KVM_SET_IDENTITY_MAP_ADDR, &guest_phys_addr) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_map_memory(hhal_vm_t vm, const struct hhal_mem_region *region)
{
    struct kvm_userspace_memory_region kvm_region;

    if (hhal_check_vm(vm) != HHAL_OK || region == NULL) {
        return HHAL_ERR_INVALID;
    }

    memset(&kvm_region, 0, sizeof(kvm_region));
    kvm_region.slot = region->slot;
    kvm_region.flags = region->flags;
    kvm_region.guest_phys_addr = region->guest_phys_addr;
    kvm_region.memory_size = region->memory_size;
    kvm_region.userspace_addr = region->host_user_addr;

    if (ioctl(vm->vm_fd, KVM_SET_USER_MEMORY_REGION, &kvm_region) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_unmap_memory(hhal_vm_t vm, uint32_t slot)
{
    struct kvm_userspace_memory_region kvm_region;

    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    memset(&kvm_region, 0, sizeof(kvm_region));
    kvm_region.slot = slot;

    if (ioctl(vm->vm_fd, KVM_SET_USER_MEMORY_REGION, &kvm_region) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_get_dirty_log(hhal_vm_t vm, struct hhal_dirty_log *log)
{
    struct kvm_dirty_log kvm_log;

    if (hhal_check_vm(vm) != HHAL_OK || log == NULL || log->bitmap == NULL) {
        return HHAL_ERR_INVALID;
    }

    memset(&kvm_log, 0, sizeof(kvm_log));
    kvm_log.slot = log->slot;
    kvm_log.dirty_bitmap = log->bitmap;

    if (ioctl(vm->vm_fd, KVM_GET_DIRTY_LOG, &kvm_log) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_clear_dirty_log(hhal_vm_t vm, const struct hhal_dirty_log *log)
{
#ifdef KVM_CLEAR_DIRTY_LOG
    struct kvm_clear_dirty_log kvm_log;

    if (hhal_check_vm(vm) != HHAL_OK || log == NULL || log->bitmap == NULL) {
        return HHAL_ERR_INVALID;
    }

    memset(&kvm_log, 0, sizeof(kvm_log));
    kvm_log.slot = log->slot;
    kvm_log.num_pages = log->num_pages;
    kvm_log.first_page = log->first_page;
    kvm_log.dirty_bitmap = log->bitmap;

    if (ioctl(vm->vm_fd, KVM_CLEAR_DIRTY_LOG, &kvm_log) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
#else
    (void)vm;
    (void)log;
    return HHAL_ERR_UNSUPPORTED;
#endif
}

int hhal_vm_create_irqchip(hhal_vm_t vm)
{
    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }
    if (ioctl(vm->vm_fd, KVM_CREATE_IRQCHIP, 0) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_set_irq_routing(hhal_vm_t vm, const struct hhal_irq_routing_table *table)
{
    struct kvm_irq_routing *routing;
    size_t bytes;
    uint32_t i;

    if (hhal_check_vm(vm) != HHAL_OK || table == NULL) {
        return HHAL_ERR_INVALID;
    }
    if (table->num_routes > 0 && table->routes == NULL) {
        return HHAL_ERR_INVALID;
    }

    bytes = sizeof(*routing) +
            ((size_t)table->num_routes * sizeof(struct kvm_irq_routing_entry));
    routing = calloc(1, bytes);
    if (routing == NULL) {
        return HHAL_ERR_NOMEM;
    }

    routing->nr = table->num_routes;
    routing->flags = table->flags;

    for (i = 0; i < table->num_routes; ++i) {
        const struct hhal_irq_route *src = &table->routes[i];
        struct kvm_irq_routing_entry *dst = &routing->entries[i];

        dst->gsi = src->gsi;
        dst->flags = 0;

        switch (src->type) {
        case HHAL_IRQ_ROUTE_IRQCHIP:
            dst->type = KVM_IRQ_ROUTING_IRQCHIP;
            dst->u.irqchip.irqchip = src->u.irqchip.irqchip_id;
            dst->u.irqchip.pin = src->u.irqchip.pin;
            break;
        case HHAL_IRQ_ROUTE_MSI:
            dst->type = KVM_IRQ_ROUTING_MSI;
            dst->u.msi.address_lo = (uint32_t)(src->u.msi.address & 0xffffffffu);
            dst->u.msi.address_hi = (uint32_t)(src->u.msi.address >> 32);
            dst->u.msi.data = src->u.msi.data;
            dst->u.msi.devid = src->u.msi.devid;
            break;
        default:
            free(routing);
            return HHAL_ERR_UNSUPPORTED;
        }
    }

    if (ioctl(vm->vm_fd, KVM_SET_GSI_ROUTING, routing) < 0) {
        int saved_errno = errno;
        free(routing);
        return hhal_linux_error(saved_errno);
    }

    free(routing);
    return HHAL_OK;
}

int hhal_vm_irq_line(hhal_vm_t vm, uint32_t gsi, uint32_t level)
{
    struct kvm_irq_level irq = {0};

    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    irq.irq = gsi;
    irq.level = (int)level;
    if (ioctl(vm->vm_fd, KVM_IRQ_LINE, &irq) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_irq_line_status(hhal_vm_t vm, struct hhal_irq_line_status *irq)
{
#ifdef KVM_IRQ_LINE_STATUS
    struct kvm_irq_level kvm_irq = {0};

    if (hhal_check_vm(vm) != HHAL_OK || irq == NULL) {
        return HHAL_ERR_INVALID;
    }

    kvm_irq.irq = irq->gsi;
    kvm_irq.level = (int)irq->level;
    if (ioctl(vm->vm_fd, KVM_IRQ_LINE_STATUS, &kvm_irq) < 0) {
        return hhal_linux_error(errno);
    }

    irq->status = (uint32_t)kvm_irq.status;
    return HHAL_OK;
#else
    (void)vm;
    (void)irq;
    return HHAL_ERR_UNSUPPORTED;
#endif
}

int hhal_vm_bind_irqfd(hhal_vm_t vm, const struct hhal_irqfd *irqfd)
{
    struct kvm_irqfd kvm_irqfd = {0};

    if (hhal_check_vm(vm) != HHAL_OK || irqfd == NULL) {
        return HHAL_ERR_INVALID;
    }

    kvm_irqfd.fd = (uint32_t)irqfd->fd;
    kvm_irqfd.gsi = irqfd->gsi;
    kvm_irqfd.flags = irqfd->flags;
    kvm_irqfd.resamplefd = (uint32_t)irqfd->resample_fd;

    if (ioctl(vm->vm_fd, KVM_IRQFD, &kvm_irqfd) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_bind_ioevent(hhal_vm_t vm, const struct hhal_ioevent *ioevent)
{
    struct kvm_ioeventfd kvm_ioevent = {0};

    if (hhal_check_vm(vm) != HHAL_OK || ioevent == NULL) {
        return HHAL_ERR_INVALID;
    }

    kvm_ioevent.datamatch = ioevent->data;
    kvm_ioevent.addr = ioevent->addr;
    kvm_ioevent.len = ioevent->len;
    kvm_ioevent.fd = (uint32_t)ioevent->fd;
    kvm_ioevent.flags = ioevent->flags;

    if (ioctl(vm->vm_fd, KVM_IOEVENTFD, &kvm_ioevent) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vm_create_pit(hhal_vm_t vm, const struct hhal_pit_config *cfg)
{
#ifdef KVM_CREATE_PIT2
    struct kvm_pit_config pit = {0};

    if (hhal_check_vm(vm) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }
    if (cfg != NULL) {
        pit.flags = cfg->flags;
    }
    if (ioctl(vm->vm_fd, KVM_CREATE_PIT2, &pit) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
#else
    (void)vm;
    (void)cfg;
    return HHAL_ERR_UNSUPPORTED;
#endif
}

int hhal_vm_get_clock(hhal_vm_t vm, struct hhal_clock_data *clock)
{
    struct kvm_clock_data kvm_clock = {0};

    if (hhal_check_vm(vm) != HHAL_OK || clock == NULL) {
        return HHAL_ERR_INVALID;
    }
    if (ioctl(vm->vm_fd, KVM_GET_CLOCK, &kvm_clock) < 0) {
        return hhal_linux_error(errno);
    }

    clock->value_ns = kvm_clock.clock;
    clock->flags = kvm_clock.flags;
    return HHAL_OK;
}

int hhal_vm_set_clock(hhal_vm_t vm, const struct hhal_clock_data *clock)
{
    struct kvm_clock_data kvm_clock = {0};

    if (hhal_check_vm(vm) != HHAL_OK || clock == NULL) {
        return HHAL_ERR_INVALID;
    }

    kvm_clock.clock = clock->value_ns;
    kvm_clock.flags = clock->flags;
    if (ioctl(vm->vm_fd, KVM_SET_CLOCK, &kvm_clock) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vcpu_create(hhal_vm_t vm, const struct hhal_vcpu_config *cfg, hhal_vcpu_t *out_vcpu)
{
    struct hhal_vcpu *vcpu;
    int vcpu_fd;
    int mmap_size;

    if (hhal_check_vm(vm) != HHAL_OK || cfg == NULL || out_vcpu == NULL) {
        return HHAL_ERR_INVALID;
    }

    mmap_size = ioctl(vm->sys_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    if (mmap_size < 0) {
        return hhal_linux_error(errno);
    }

    vcpu_fd = ioctl(vm->vm_fd, KVM_CREATE_VCPU, cfg->vcpu_id);
    if (vcpu_fd < 0) {
        return hhal_linux_error(errno);
    }

    vcpu = calloc(1, sizeof(*vcpu));
    if (vcpu == NULL) {
        hhal_close_fd(&vcpu_fd);
        return HHAL_ERR_NOMEM;
    }

    vcpu->run = mmap(NULL, (size_t)mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu_fd, 0);
    if (vcpu->run == MAP_FAILED) {
        int saved_errno = errno;
        hhal_close_fd(&vcpu_fd);
        free(vcpu);
        return hhal_linux_error(saved_errno);
    }

    vcpu->vm = vm;
    vcpu->vcpu_fd = vcpu_fd;
    vcpu->vcpu_id = cfg->vcpu_id;
    vcpu->run_mmap_size = (size_t)mmap_size;
    *out_vcpu = vcpu;
    return HHAL_OK;
}

int hhal_vcpu_destroy(hhal_vcpu_t vcpu)
{
    if (hhal_check_vcpu(vcpu) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    if (vcpu->run != NULL && vcpu->run != MAP_FAILED) {
        munmap(vcpu->run, vcpu->run_mmap_size);
        vcpu->run = NULL;
    }
    hhal_close_fd(&vcpu->vcpu_fd);
    free(vcpu);
    return HHAL_OK;
}

int hhal_vcpu_run(hhal_vcpu_t vcpu, struct hhal_run *run)
{
    if (hhal_check_vcpu(vcpu) != HHAL_OK || run == NULL) {
        return HHAL_ERR_INVALID;
    }

    if (ioctl(vcpu->vcpu_fd, KVM_RUN, 0) < 0) {
        if (errno == EINTR) {
            hhal_zero_run(run);
            run->exit_reason = HHAL_EXIT_SIGNAL;
            return HHAL_OK;
        }
        return hhal_linux_error(errno);
    }

    hhal_translate_run_exit(run, vcpu->run);
    return HHAL_OK;
}

int hhal_vcpu_translate_gva(hhal_vcpu_t vcpu, struct hhal_gva_translation *translation)
{
    struct kvm_translation kvm_translation = {0};

    if (hhal_check_vcpu(vcpu) != HHAL_OK || translation == NULL) {
        return HHAL_ERR_INVALID;
    }

    kvm_translation.linear_address = translation->gva;
    if (ioctl(vcpu->vcpu_fd, KVM_TRANSLATE, &kvm_translation) < 0) {
        return hhal_linux_error(errno);
    }

    translation->gpa = kvm_translation.physical_address;
    translation->flags = 0;
    if (kvm_translation.valid) {
        translation->flags |= 1u << 0;
    }
    if (kvm_translation.writeable) {
        translation->flags |= 1u << 1;
    }
    if (kvm_translation.usermode) {
        translation->flags |= 1u << 2;
    }
    return HHAL_OK;
}

int hhal_vcpu_get_state(hhal_vcpu_t vcpu, struct hhal_state_blob *state)
{
    int rc;

    if (hhal_check_vcpu(vcpu) != HHAL_OK || state == NULL) {
        return HHAL_ERR_INVALID;
    }

    switch (state->id) {
    case HHAL_VCPU_STATE_REGS:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_REGS, sizeof(struct kvm_regs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_REGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_regs);
        return HHAL_OK;
    case HHAL_VCPU_STATE_SREGS:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_SREGS, sizeof(struct kvm_sregs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_SREGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_sregs);
        return HHAL_OK;
    case HHAL_VCPU_STATE_CPUID:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_CPUID,
                                     hhal_kvm_cpuid_min_size(state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_CPUID2, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = hhal_kvm_cpuid_min_size(state);
        return HHAL_OK;
    case HHAL_VCPU_STATE_MSRS:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_MSRS,
                                     hhal_kvm_msrs_min_size(state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_MSRS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = hhal_kvm_msrs_min_size(state);
        return HHAL_OK;
    case HHAL_VCPU_STATE_FPU:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_FPU, sizeof(struct kvm_fpu));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_FPU, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_fpu);
        return HHAL_OK;
    case HHAL_VCPU_STATE_LAPIC:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_LAPIC, sizeof(struct kvm_lapic_state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_LAPIC, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_lapic_state);
        return HHAL_OK;
    case HHAL_VCPU_STATE_MP:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_MP, sizeof(struct kvm_mp_state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_MP_STATE, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_mp_state);
        return HHAL_OK;
    case HHAL_VCPU_STATE_EVENTS:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_EVENTS, sizeof(struct kvm_vcpu_events));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_VCPU_EVENTS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_vcpu_events);
        return HHAL_OK;
    case HHAL_VCPU_STATE_DEBUG:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_DEBUG, sizeof(struct kvm_debugregs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_DEBUGREGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_debugregs);
        return HHAL_OK;
    case HHAL_VCPU_STATE_XSAVE:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_XSAVE, sizeof(struct kvm_xsave));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_XSAVE, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_xsave);
        return HHAL_OK;
    case HHAL_VCPU_STATE_XCRS:
        rc = hhal_require_state_blob(state, HHAL_VCPU_STATE_XCRS, sizeof(struct kvm_xcrs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_GET_XCRS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        state->size = sizeof(struct kvm_xcrs);
        return HHAL_OK;
    case HHAL_VCPU_STATE_SIGNAL_MASK:
        return HHAL_ERR_UNSUPPORTED;
    default:
        return HHAL_ERR_UNSUPPORTED;
    }
}

int hhal_vcpu_set_state(hhal_vcpu_t vcpu, const struct hhal_state_blob *state)
{
    int rc;

    if (hhal_check_vcpu(vcpu) != HHAL_OK || state == NULL) {
        return HHAL_ERR_INVALID;
    }

    switch (state->id) {
    case HHAL_VCPU_STATE_REGS:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_REGS, sizeof(struct kvm_regs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_REGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_SREGS:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_SREGS, sizeof(struct kvm_sregs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_SREGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_CPUID:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_CPUID,
                                           hhal_kvm_cpuid_min_size(state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_CPUID2, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_MSRS:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_MSRS,
                                           hhal_kvm_msrs_min_size(state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_MSRS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_FPU:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_FPU, sizeof(struct kvm_fpu));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_FPU, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_LAPIC:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_LAPIC, sizeof(struct kvm_lapic_state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_LAPIC, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_MP:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_MP, sizeof(struct kvm_mp_state));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_MP_STATE, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_EVENTS:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_EVENTS, sizeof(struct kvm_vcpu_events));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_VCPU_EVENTS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_DEBUG:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_DEBUG, sizeof(struct kvm_debugregs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_DEBUGREGS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_XSAVE:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_XSAVE, sizeof(struct kvm_xsave));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_XSAVE, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_XCRS:
        rc = hhal_require_const_state_blob(state, HHAL_VCPU_STATE_XCRS, sizeof(struct kvm_xcrs));
        if (rc != HHAL_OK) {
            return rc;
        }
        if (ioctl(vcpu->vcpu_fd, KVM_SET_XCRS, state->data) < 0) {
            return hhal_linux_error(errno);
        }
        return HHAL_OK;
    case HHAL_VCPU_STATE_SIGNAL_MASK:
        if (state->data == NULL || (state->size % sizeof(uint64_t)) != 0) {
            return HHAL_ERR_INVALID;
        }
        return hhal_vcpu_signal_mask(vcpu,
                                     (const uint64_t *)state->data,
                                     state->size / sizeof(uint64_t));
    default:
        return HHAL_ERR_UNSUPPORTED;
    }
}

int hhal_vcpu_interrupt(hhal_vcpu_t vcpu, uint32_t vector)
{
    struct kvm_interrupt irq = {0};

    if (hhal_check_vcpu(vcpu) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }

    irq.irq = (uint32_t)vector;
    if (ioctl(vcpu->vcpu_fd, KVM_INTERRUPT, &irq) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vcpu_nmi(hhal_vcpu_t vcpu)
{
    if (hhal_check_vcpu(vcpu) != HHAL_OK) {
        return HHAL_ERR_INVALID;
    }
    if (ioctl(vcpu->vcpu_fd, KVM_NMI, 0) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}

int hhal_vcpu_signal_mask(hhal_vcpu_t vcpu, const uint64_t *mask_words, size_t num_words)
{
    struct {
        struct kvm_signal_mask hdr;
        uint64_t words[1];
    } sigmask;
    size_t bytes;

    if (hhal_check_vcpu(vcpu) != HHAL_OK || mask_words == NULL) {
        return HHAL_ERR_INVALID;
    }

    bytes = num_words * sizeof(uint64_t);
    if (num_words != 1u) {
        return HHAL_ERR_INVALID;
    }

    memset(&sigmask, 0, sizeof(sigmask));
    sigmask.hdr.len = bytes;
    memcpy(sigmask.words, mask_words, bytes);

    if (ioctl(vcpu->vcpu_fd, KVM_SET_SIGNAL_MASK, &sigmask) < 0) {
        return hhal_linux_error(errno);
    }
    return HHAL_OK;
}
