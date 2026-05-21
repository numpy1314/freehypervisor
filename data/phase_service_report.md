# HHAL Host Service Dependency Report

Total mapped events: 1412054

## Summary

| Service Class | Count | Unique Services |
|---|---:|---:|
| EVENT | 680732 | 3 |
| IO | 4201 | 13 |
| IRQ | 698264 | 9 |
| MEMORY | 1804 | 10 |
| SIGNAL | 53 | 2 |
| SYNC | 5124 | 1 |
| THREAD | 12 | 2 |
| TIMER | 70 | 9 |
| VCPU | 21710 | 28 |
| VM | 84 | 3 |

## Phase Breakdown

| Phase | Events |
|---|---:|
| VM_CREATE | 26261 |
| VM_BOOT | 44179 |
| STEADY_IDLE | 5 |
| STEADY_IO | 1341609 |
| VM_DESTROY | 0 |

## EVENT Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_EVENT_CREATE | eventfd2 | 9 | 9 | 0 | 0 | 0 | 0 |
| HV_EVENT_POLL_INIT | epoll_create1 | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_EVENT_POLL_WAIT | ppoll | 680721 | 978 | 19951 | 3 | 659789 | 0 |

## IO Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_IO_BIND_EVENT | KVM_IOEVENTFD | 12 | 10 | 0 | 0 | 2 | 0 |
| HV_IO_CLOSE | close | 122 | 115 | 0 | 0 | 7 | 0 |
| HV_IO_DEVICE_GET_ATTR | KVM_GET_DEVICE_ATTR | 4 | 4 | 0 | 0 | 0 | 0 |
| HV_IO_FCNTL | fcntl | 25 | 20 | 0 | 0 | 5 | 0 |
| HV_IO_MMIO_COALESCED_REGISTER | KVM_REGISTER_COALESCED_MMIO | 22 | 22 | 0 | 0 | 0 | 0 |
| HV_IO_MMIO_COALESCED_UNREGISTER | KVM_UNREGISTER_COALESCED_MMIO | 10 | 10 | 0 | 0 | 0 | 0 |
| HV_IO_OPEN | openat | 125 | 124 | 0 | 0 | 1 | 0 |
| HV_IO_PREAD | pread64 | 8 | 8 | 0 | 0 | 0 | 0 |
| HV_IO_READ | read | 407 | 291 | 2 | 0 | 114 | 0 |
| HV_IO_READV | readv | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_IO_STAT | newfstatat | 118 | 118 | 0 | 0 | 0 | 0 |
| HV_IO_WRITE | write | 308 | 191 | 2 | 0 | 115 | 0 |
| HV_IO_WRITEV | writev | 3039 | 320 | 344 | 0 | 2375 | 0 |

## IRQ Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_IRQ_BIND_EVENT | KVM_IRQFD | 4 | 2 | 0 | 0 | 2 | 0 |
| HV_IRQ_CHIP_CREATE | KVM_CREATE_IRQCHIP | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_IRQ_CHIP_SET | KVM_SET_IRQCHIP | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_IRQ_LAPIC_GET | KVM_GET_LAPIC | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_IRQ_LAPIC_SET | KVM_SET_LAPIC | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_IRQ_LINE_STATUS | KVM_IRQ_LINE_STATUS | 698244 | 4950 | 21912 | 2 | 671380 | 0 |
| HV_IRQ_MSI_SIGNAL | KVM_SIGNAL_MSI | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_IRQ_ROUTE_CONFIG | KVM_SET_GSI_ROUTING | 5 | 5 | 0 | 0 | 0 | 0 |
| HV_IRQ_VAPIC_SET_ADDR | KVM_SET_VAPIC_ADDR | 1 | 1 | 0 | 0 | 0 | 0 |

## MEMORY Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_MEM_ADVISE | madvise | 674 | 544 | 130 | 0 | 0 | 0 |
| HV_MEM_ALLOC_BACKING | mmap | 444 | 444 | 0 | 0 | 0 | 0 |
| HV_MEM_DIRTY_LOG_READ | KVM_GET_DIRTY_LOG | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_MEM_FREE_BACKING | munmap | 23 | 23 | 0 | 0 | 0 | 0 |
| HV_MEM_HEAP_ADJUST | brk | 119 | 119 | 0 | 0 | 0 | 0 |
| HV_MEM_MEMFD_CREATE | memfd_create | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_MEM_PROTECT | mprotect | 449 | 449 | 0 | 0 | 0 | 0 |
| HV_MEM_REGISTER_GPA_RANGE | KVM_SET_USER_MEMORY_REGION | 88 | 88 | 0 | 0 | 0 | 0 |
| HV_MEM_SET_IDENTITY_MAP | KVM_SET_IDENTITY_MAP_ADDR | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_MEM_SET_TSS | KVM_SET_TSS_ADDR | 1 | 1 | 0 | 0 | 0 | 0 |

## SIGNAL Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_SIGNAL_HANDLER_SET | rt_sigaction | 8 | 8 | 0 | 0 | 0 | 0 |
| HV_SIGNAL_MASK | rt_sigprocmask | 45 | 40 | 1 | 0 | 4 | 0 |

## SYNC Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_SYNC_FUTEX | futex | 5124 | 1449 | 552 | 0 | 3123 | 0 |

## THREAD Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_THREAD_CREATE | clone3 | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_THREAD_SIGNAL | tgkill | 9 | 7 | 0 | 0 | 2 | 0 |

## TIMER Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_CLOCK_CTRL | KVM_KVMCLOCK_CTRL | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_CLOCK_GET | KVM_GET_CLOCK | 2 | 1 | 0 | 0 | 1 | 0 |
| HV_CLOCK_SET | KVM_SET_CLOCK | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_TIMER_PIT_CREATE | KVM_CREATE_PIT2 | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_TIMER_PIT_GET | KVM_GET_PIT2 | 3 | 2 | 0 | 0 | 1 | 0 |
| HV_TIMER_PIT_SET | KVM_SET_PIT2 | 4 | 4 | 0 | 0 | 0 | 0 |
| HV_TIMER_SLEEP | clock_nanosleep | 55 | 53 | 2 | 0 | 0 | 0 |
| HV_TIMER_TSC_GET_FREQ | KVM_GET_TSC_KHZ | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_TIMER_TSC_SET_FREQ | KVM_SET_TSC_KHZ | 1 | 1 | 0 | 0 | 0 | 0 |

## VCPU Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_VCPU_CPUID_QUERY | KVM_GET_SUPPORTED_CPUID | 7 | 7 | 0 | 0 | 0 | 0 |
| HV_VCPU_CREATE | KVM_CREATE_VCPU | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_ENTER | KVM_RUN | 21625 | 15657 | 1283 | 0 | 4685 | 0 |
| HV_VCPU_GET_DEBUGREGS | KVM_GET_DEBUGREGS | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_GET_EVENTS | KVM_GET_VCPU_EVENTS | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_GET_MP_STATE | KVM_GET_MP_STATE | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_GET_MSRS | KVM_GET_MSRS | 14 | 13 | 0 | 0 | 1 | 0 |
| HV_VCPU_GET_REGS | KVM_GET_REGS | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_GET_SREGS | KVM_GET_SREGS2 | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_GET_XCRS | KVM_GET_XCRS | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_INJECT_SMI | KVM_SMI | 11 | 11 | 0 | 0 | 0 | 0 |
| HV_VCPU_MMAP_SIZE_QUERY | KVM_GET_VCPU_MMAP_SIZE | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_MSR_FEATURE_QUERY | KVM_GET_MSR_FEATURE_INDEX_LIST | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_MSR_LIST_QUERY | KVM_GET_MSR_INDEX_LIST | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_CPUID | KVM_SET_CPUID2 | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_DEBUGREGS | KVM_SET_DEBUGREGS | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_EVENTS | KVM_SET_VCPU_EVENTS | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_MP_STATE | KVM_SET_MP_STATE | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_MSRS | KVM_SET_MSRS | 8 | 8 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_REGS | KVM_SET_REGS | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_SREGS | KVM_SET_SREGS2 | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_XCRS | KVM_SET_XCRS | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_SET_XSAVE | KVM_SET_XSAVE | 3 | 3 | 0 | 0 | 0 | 0 |
| HV_VCPU_STATS_FD | KVM_GET_STATS_FD | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_TPR_ACCESS_REPORTING | KVM_TPR_ACCESS_REPORTING | 2 | 2 | 0 | 0 | 0 | 0 |
| HV_VCPU_X86_MCE_CAP_QUERY | KVM_X86_GET_MCE_CAP_SUPPORTED | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_X86_MCE_SETUP | KVM_X86_SETUP_MCE | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VCPU_X86_MSR_FILTER_SET | KVM_X86_SET_MSR_FILTER | 1 | 1 | 0 | 0 | 0 | 0 |

## VM Services

| Service | Evidence | Total | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY |
|---|---|---: | ---: | ---: | ---: | ---: | ---: |
| HV_VM_CAPABILITY_QUERY | KVM_CHECK_EXTENSION, KVM_GET_API_VERSION | 77 | 75 | 0 | 0 | 2 | 0 |
| HV_VM_CREATE | KVM_CREATE_VM | 1 | 1 | 0 | 0 | 0 | 0 |
| HV_VM_ENABLE_CAP | KVM_ENABLE_CAP | 6 | 6 | 0 | 0 | 0 | 0 |

