/* SPDX-License-Identifier: Apache-2.0 */
#include <freehypervisor/zephyr_adapter.h>

#include <zephyr/kernel.h>

static struct k_timer fh_oneshot;

#ifdef CONFIG_FREEHYPERVISOR_CONTRACT_TESTS
static atomic_t fh_timer_suppress;
static atomic_t fh_timer_count;
static atomic_t fh_timer_last_fire;
#endif

uint64_t fh_monotonic_nanos(void)
{
	return k_ticks_to_ns_floor64(k_uptime_ticks());
}

static void fh_timer_expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);
#ifdef CONFIG_FREEHYPERVISOR_CONTRACT_TESTS
	atomic_inc(&fh_timer_count);
	atomic_set(&fh_timer_last_fire, (atomic_val_t)fh_monotonic_nanos());
	if (atomic_get(&fh_timer_suppress) != 0) {
		return;
	}
#endif
#ifdef CONFIG_FREEHYPERVISOR_CORE
	fh_rust_timer_expired();
#endif
}

int fh_time_init(void)
{
	k_timer_init(&fh_oneshot, fh_timer_expiry, NULL);
	return 0;
}

void fh_set_oneshot_timer(uint64_t deadline_ns)
{
	uint64_t now = fh_monotonic_nanos();
	uint64_t delay = deadline_ns > now ? deadline_ns - now : 1;
	k_timer_start(&fh_oneshot, K_NSEC(delay), K_NO_WAIT);
}

#ifdef CONFIG_FREEHYPERVISOR_CONTRACT_TESTS
void fh_test_timer_suppress_callback(bool suppress)
{
	atomic_set(&fh_timer_suppress, suppress ? 1 : 0);
	atomic_set(&fh_timer_count, 0);
	atomic_set(&fh_timer_last_fire, 0);
}

uint64_t fh_test_timer_expiry_count(void)
{
	return (uint64_t)atomic_get(&fh_timer_count);
}

uint64_t fh_test_timer_last_fire_ns(void)
{
	return (uint64_t)atomic_get(&fh_timer_last_fire);
}
#endif
