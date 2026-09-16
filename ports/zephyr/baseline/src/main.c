/* SPDX-License-Identifier: Apache-2.0 */
#include <zephyr/kernel.h>
#include <zephyr/kernel/internal/mm.h>
#include <zephyr/drivers/interrupt_controller/loapic.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#define BASELINE_IPI_VECTOR 239
#define FIRST_IRQ_VECTOR 32
#define IRQ_VECTOR_COUNT (256 - FIRST_IRQ_VECTOR)

extern void (*x86_irq_funcs[IRQ_VECTOR_COUNT])(const void *arg);
extern const void *x86_irq_args[IRQ_VECTOR_COUNT];
extern int arch_page_phys_get(void *virt, uintptr_t *phys);

K_THREAD_STACK_DEFINE(worker_stack, 4096);
static struct k_thread worker_thread;
K_SEM_DEFINE(worker_go, 0, 1);
K_SEM_DEFINE(worker_done, 0, 1);
K_SEM_DEFINE(timer_done, 0, 1);
K_SEM_DEFINE(ipi_done, 0, 1);
K_TIMER_DEFINE(baseline_timer, NULL, NULL);
static struct k_spinlock baseline_lock;
static unsigned int protected_value;
static atomic_t worker_cpu = ATOMIC_INIT(-1);
static atomic_t ipi_cpu = ATOMIC_INIT(-1);
static uint8_t translation_page[4096] __aligned(4096);

static void timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	k_sem_give(&timer_done);
}

static void ipi_handler(const void *arg)
{
	ARG_UNUSED(arg);
	atomic_set(&ipi_cpu, (atomic_val_t)arch_curr_cpu()->id);
	k_sem_give(&ipi_done);
}

static void worker(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);
	atomic_set(&worker_cpu, (atomic_val_t)arch_curr_cpu()->id);
	k_sem_take(&worker_go, K_FOREVER);
	k_spinlock_key_t key = k_spin_lock(&baseline_lock);
	protected_value++;
	k_spin_unlock(&baseline_lock, key);
	k_sem_give(&worker_done);
}

int main(void)
{
	bool pass = arch_num_cpus() == 2;
	printk("BASELINE cpu_count=%u current_cpu=%u\n", arch_num_cpus(), arch_curr_cpu()->id);

	k_tid_t tid = k_thread_create(&worker_thread, worker_stack,
				      K_THREAD_STACK_SIZEOF(worker_stack), worker,
				      NULL, NULL, NULL, K_PRIO_PREEMPT(2), 0, K_FOREVER);
	k_thread_cpu_mask_clear(tid);
	k_thread_cpu_mask_enable(tid, 1);
	k_thread_start(tid);
	for (int i = 0; i < 100 && atomic_get(&worker_cpu) < 0; ++i) {
		k_sleep(K_MSEC(1));
	}
	pass &= atomic_get(&worker_cpu) == 1;
	k_sem_give(&worker_go);
	pass &= k_sem_take(&worker_done, K_MSEC(100)) == 0;
	pass &= protected_value == 1;
	printk("BASELINE thread_cpu=%ld semaphore=PASS spinlock=%s\n",
	       (long)atomic_get(&worker_cpu), protected_value == 1 ? "PASS" : "FAIL");

	k_timer_init(&baseline_timer, timer_expiry, NULL);
	uint64_t before = k_ticks_to_ns_floor64(k_uptime_ticks());
	k_timer_start(&baseline_timer, K_MSEC(5), K_NO_WAIT);
	pass &= k_sem_take(&timer_done, K_MSEC(100)) == 0;
	uint64_t after = k_ticks_to_ns_floor64(k_uptime_ticks());
	pass &= after >= before;
	printk("BASELINE timer monotonic=%s before=%llu after=%llu\n",
	       after >= before ? "PASS" : "FAIL", before, after);

	uintptr_t pa = 0;
	int rc = arch_page_phys_get(translation_page, &pa);
	pass &= rc == 0 && pa != 0;
	printk("BASELINE translation VA=%p PA=%#lx result=%s\n",
	       translation_page, pa, rc == 0 && pa != 0 ? "PASS" : "FAIL");

	unsigned int key = irq_lock();
	x86_irq_funcs[BASELINE_IPI_VECTOR - FIRST_IRQ_VECTOR] = ipi_handler;
	x86_irq_args[BASELINE_IPI_VECTOR - FIRST_IRQ_VECTOR] = NULL;
	irq_unlock(key);
	z_loapic_ipi(1, LOAPIC_ICR_IPI_SPECIFIC, BASELINE_IPI_VECTOR);
	pass &= k_sem_take(&ipi_done, K_MSEC(100)) == 0;
	pass &= atomic_get(&ipi_cpu) == 1;
	printk("BASELINE dedicated_ipi vector=%d cpu=%ld result=%s\n",
	       BASELINE_IPI_VECTOR, (long)atomic_get(&ipi_cpu),
	       atomic_get(&ipi_cpu) == 1 ? "PASS" : "FAIL");

	k_thread_join(&worker_thread, K_FOREVER);
	printk("BASELINE_RESULT=%s\n", pass ? "PASS" : "FAIL");
	k_sleep(K_MSEC(20));
	sys_reboot(SYS_REBOOT_COLD);
	return 0;
}
