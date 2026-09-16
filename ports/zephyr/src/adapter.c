/* SPDX-License-Identifier: Apache-2.0 */
#include <freehypervisor/zephyr_adapter.h>

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#include <errno.h>

int fh_memory_init(void);
int fh_time_init(void);
K_MUTEX_DEFINE(fh_console_mutex);

int fh_adapter_init(void)
{
	int rc = fh_memory_init();

	if (rc != 0) {
		return rc;
	}
	rc = fh_time_init();
	if (rc != 0) {
		return rc;
	}
#ifdef CONFIG_FREEHYPERVISOR_DEDICATED_IPI
	rc = fh_hv_ipi_init();
#endif
	return rc;
}

void fh_console_write(const uint8_t *bytes, size_t length)
{
	for (size_t i = 0; i < length; ++i) {
		char c = (char)bytes[i];
		if (c == '\n') {
			printk("\r");
		}
		printk("%c", c);
	}
}

size_t fh_console_read(uint8_t *bytes, size_t length)
{
	ARG_UNUSED(bytes);
	ARG_UNUSED(length);
	return 0;
}

void fh_console_acquire(void)
{
	k_mutex_lock(&fh_console_mutex, K_FOREVER);
}

void fh_console_release(void)
{
	k_mutex_unlock(&fh_console_mutex);
}

void *fh_rust_alloc(size_t size, size_t align)
{
	if (size == 0) {
		size = 1;
	}
	if (align < sizeof(void *)) {
		align = sizeof(void *);
	}
	return k_aligned_alloc(align, size);
}

void fh_rust_dealloc(void *ptr, size_t size, size_t align)
{
	ARG_UNUSED(size);
	ARG_UNUSED(align);
	k_free(ptr);
}

void fh_rust_abort(void)
{
	printk("FH: Rust panic; rebooting\n");
	sys_reboot(SYS_REBOOT_COLD);
	CODE_UNREACHABLE;
}

size_t fh_host_cpu_count(void)
{
	return arch_num_cpus();
}

size_t fh_current_cpu_id(void)
{
	return arch_curr_cpu()->id;
}

uint32_t fh_host_tsc_frequency_mhz(void)
{
	return (uint32_t)(CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / 1000000U);
}
