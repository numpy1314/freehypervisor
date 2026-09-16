.code16
.section .text
.global _start
_start:
	movl $0x48564b31, %eax
	vmmcall
	movl $0x20000000, %ecx
1:
	decl %ecx
	jnz 1b
	movl $0x4b52534d, %eax
	vmmcall
	movw $0x604, %dx
	movl $0x2000, %eax
	outw %ax, %dx
	hlt
