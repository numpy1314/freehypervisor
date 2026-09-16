.code16
.section .text
.global _start
_start:
	movl $0x48564d31, %eax
	vmmcall
	xorl %eax, %eax
	cpuid
	movl $0x52534d31, %eax
	vmmcall
	rdtsc
	movl $0x52534d32, %eax
	vmmcall
	movw $0x604, %dx
	movl $0x2000, %eax
	outw %ax, %dx
	hlt
