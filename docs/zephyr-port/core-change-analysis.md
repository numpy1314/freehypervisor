# Core change analysis

## Result

The port did not add a Zephyr hook or a new substrate capability. It did require three small, host-neutral patches to the pinned Core because executing it under an eagerly scheduled host and completing a full static lifecycle exposed two ordering bugs and one SVM exit-decoding bug.

The build applies patches only to the generated `build/zephyr/core-src` tree. The pinned Core checkout remains untouched.

| Patch | Files | Diff | Root cause | Why the adapter cannot correctly hide it |
|---|---:|---:|---|---|
| `0001-publish-primary-vcpu-before-spawn.patch` | 1 | `+1/-2` | `setup_vm_primary_vcpu` published `VM_VCPU_TASKS` only after host spawn returned. Zephyr may run the new task before return, so the vCPU could fail to find its owner/wait queue. | Delaying every host task would weaken the normal `spawn` semantics and encode a Core ordering assumption in each OS adapter. Publishing the owner first is the correct host-neutral lifetime order. |
| `0002-svm-validate-address-size-only-for-string-io.patch` | 1 | `+9/-5` | The SVM backend rejected scalar IO exits when EXITINFO's address-size field was zero. That field is relevant to string IO; QEMU can leave it zero for scalar `OUT`. | Exit decoding belongs to the architecture backend. An adapter must not rewrite SVM exit information or emulate the Guest instruction. |
| `0003-static-mode-join-tasks-and-disable-virtualization.patch` | 2 | `+52/-11` | Static mode discarded per-CPU init task handles and returned after VM stop without joining vCPU tasks or disabling per-CPU virtualization. | Task join already exists in the contract, and `hardware_disable` already exists in the Core architecture abstraction. Putting SVM/VMX teardown in the Zephyr adapter would duplicate backend state and violate ownership. |

Aggregate Core delta against `534de06e…`: **4 files, +62/-18 physical diff lines, net +44**. The formal contract remains 25 operations before and after all three patches.

## Contract-insufficiency questions

1. **Why did Linux/Asterinas appear to work while Zephyr did not?** The pinned Linux source is an older interface snapshot and is not an exact comparison. Asterinas' task implementation contains its own registration barrier, which masks the Core's publish-after-spawn assumption. Zephyr starts an explicitly started `k_thread` promptly, exposing the Core race. The SVM decoder issue appears only with the selected scalar-IO Guest/QEMU behavior. Static teardown was absent for every host, but a reboot-centric flow can conceal the resource leak.
2. **Is this a Zephyr API difference or missing host authority?** It is neither. The host already provides runnable tasks, join, physical frames and per-CPU execution. The failures are Core/backend ordering and validation issues.
3. **Could existing operations express the correct semantics?** Yes. Publication is moved before existing `spawn_task_raw`; teardown uses existing spawn/join/init-percpu and architecture `hardware_disable`; SVM decoding uses existing exit data.
4. **Is a new substrate capability required?** No. Linux and Asterinas adapters require no new operation, and the Zephyr-only IPI test hook is intentionally outside the formal contract.

## QEMU issue kept separate

`ports/zephyr/qemu/0001-tcg-svm-apply-npt-to-nonpaging-guests.patch` adds a missing stage-2 NPT walk to QEMU 8.2.2 TCG for a real-mode L2 Guest. Before the patch, Core NPT correctly mapped GPA 0 to Guest RAM, but TCG fetched from host physical address 0 because L2 paging was disabled. This is an emulator bug/workaround, not a Core or contract change. The native execution result cannot be inferred from this patched-emulator result.

## Regression evidence

- single vCPU: owner publication succeeds under immediate Zephyr scheduling;
- scalar `OUTW 0x604, 0x2000`: decoded as `SystemDown` instead of invalid SVM IOIO data;
- teardown: vCPU join completes, two pinned exit tasks run, two HSAVE frames are released, and the log contains two `succeeded to turn off SVM` events;
- four vCPUs on two pCPUs: all configured VMs complete repeatedly and both pCPUs disable SVM after every run.

These patches should be proposed upstream independently of the Zephyr adapter because their correctness argument is host-neutral.
