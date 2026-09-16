/* SPDX-License-Identifier: Apache-2.0 */
#include <freehypervisor/zephyr_adapter.h>

#include <zephyr/kernel.h>
#include <zephyr/drivers/interrupt_controller/loapic.h>
#include <zephyr/sys/printk.h>

#include <errno.h>

#define FH_IRQ_SLOTS 256
#define FH_FIRST_VECTOR 32
#define FH_VECTOR_COUNT (256 - FH_FIRST_VECTOR)

extern void (*x86_irq_funcs[FH_VECTOR_COUNT])(const void *arg);
extern const void *x86_irq_args[FH_VECTOR_COUNT];

static fh_irq_fn fh_irq_handlers[FH_IRQ_SLOTS];
static atomic_t fh_ipi_counter;
static atomic_t fh_ipi_cpu;

bool fh_irq_handle(size_t vector)
{
	if (vector >= ARRAY_SIZE(fh_irq_handlers) || fh_irq_handlers[vector] == NULL) {
		return false;
	}
	fh_irq_handlers[vector](vector);
	return true;
}

bool fh_irq_register(size_t vector, fh_irq_fn handler)
{
	if (vector >= ARRAY_SIZE(fh_irq_handlers) || handler == NULL ||
	    fh_irq_handlers[vector] != NULL) {
		return false;
	}
	fh_irq_handlers[vector] = handler;
	return true;
}

static void fh_hv_ipi_isr(const void *arg)
{
	ARG_UNUSED(arg);
	unsigned int cpu = (unsigned int)fh_current_cpu_id();
	atomic_set(&fh_ipi_cpu, (atomic_val_t)cpu);
	atomic_inc(&fh_ipi_counter);
	(void)fh_irq_handle(CONFIG_FREEHYPERVISOR_IPI_VECTOR);
	printk("FH: dedicated IPI vector=%d cpu=%u count=%lld\n",
	       CONFIG_FREEHYPERVISOR_IPI_VECTOR, cpu,
	       (long long)atomic_get(&fh_ipi_counter));
}

int fh_hv_ipi_init(void)
{
	unsigned int vector = CONFIG_FREEHYPERVISOR_IPI_VECTOR;
	if (vector < FH_FIRST_VECTOR || vector >= 256 ||
	    vector == CONFIG_SCHED_IPI_VECTOR || vector == CONFIG_TLB_IPI_VECTOR) {
		return -EINVAL;
	}
	unsigned int key = irq_lock();
	x86_irq_funcs[vector - FH_FIRST_VECTOR] = fh_hv_ipi_isr;
	x86_irq_args[vector - FH_FIRST_VECTOR] = NULL;
	irq_unlock(key);
	printk("FH: dedicated IPI vector=%u scheduler=%u tlb=%u\n",
	       vector, CONFIG_SCHED_IPI_VECTOR, CONFIG_TLB_IPI_VECTOR);
	return 0;
}

int fh_hv_ipi_send(unsigned int cpu_id)
{
	if (cpu_id >= arch_num_cpus()) {
		return -EINVAL;
	}
	z_loapic_ipi((uint8_t)cpu_id, LOAPIC_ICR_IPI_SPECIFIC,
		     CONFIG_FREEHYPERVISOR_IPI_VECTOR);
	return 0;
}

uint64_t fh_hv_ipi_count(void)
{
	return (uint64_t)atomic_get(&fh_ipi_counter);
}

unsigned int fh_hv_ipi_last_cpu(void)
{
	return (unsigned int)atomic_get(&fh_ipi_cpu);
}
