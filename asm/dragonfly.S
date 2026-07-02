
#
cc1: warning: command line option '-fno-rtti' is valid for C++/ObjC++ but not for C
# 	.file	"Xd1qj0B_rZ.c"
# 	.intel_syntax noprefix
# # GNU C17 version 8.3 [DragonFly] Release/2019-02-22 (x86_64-pc-dragonflybsd)
# #	compiled by GNU C version 8.3 [DragonFly] Release/2019-02-22, GMP version 5.0.5, MPFR version 3.1.2, MPC version 1.0.3, isl version none
# # GGC heuristics: --param ggc-min-expand=100 --param ggc-min-heapsize=131072
# # options passed:  /tmp/Xd1qj0B_rZ.c -masm=intel -mtune=generic
# # -march=x86-64 -auxbase-strip - -O3 -Wall -Wextra
# # -fno-asynchronous-unwind-tables -fno-exceptions -fno-rtti -fverbose-asm
# # options enabled:  -faggressive-loop-optimizations -falign-labels
# # -fauto-inc-dec -fbranch-count-reg -fcaller-saves
# # -fchkp-check-incomplete-type -fchkp-check-read -fchkp-check-write
# # -fchkp-instrument-calls -fchkp-narrow-bounds -fchkp-optimize
# # -fchkp-store-bounds -fchkp-use-static-bounds
# # -fchkp-use-static-const-bounds -fchkp-use-wrappers -fcode-hoisting
# # -fcombine-stack-adjustments -fcommon -fcompare-elim -fcprop-registers
# # -fcrossjumping -fcse-follow-jumps -fdefer-pop
# # -fdelete-null-pointer-checks -fdevirtualize -fdevirtualize-speculatively
# # -fdwarf2-cfi-asm -fearly-inlining -feliminate-unused-debug-types
# # -fexpensive-optimizations -fforward-propagate -ffp-int-builtin-inexact
# # -ffunction-cse -fgcse -fgcse-after-reload -fgcse-lm -fgnu-runtime
# # -fgnu-unique -fguess-branch-probability -fhoist-adjacent-loads -fident
# # -fif-conversion -fif-conversion2 -findirect-inlining -finline
# # -finline-atomics -finline-functions -finline-functions-called-once
# # -finline-small-functions -fipa-bit-cp -fipa-cp -fipa-cp-clone -fipa-icf
# # -fipa-icf-functions -fipa-icf-variables -fipa-profile -fipa-pure-const
# # -fipa-ra -fipa-reference -fipa-sra -fipa-vrp -fira-hoist-pressure
# # -fira-share-save-slots -fira-share-spill-slots
# # -fisolate-erroneous-paths-dereference -fivopts -fkeep-static-consts
# # -fleading-underscore -flifetime-dse -floop-interchange
# # -floop-unroll-and-jam -flra-remat -flto-odr-type-merging -fmath-errno
# # -fmerge-constants -fmerge-debug-strings -fmove-loop-invariants
# # -fomit-frame-pointer -foptimize-sibling-calls -foptimize-strlen
# # -fpartial-inlining -fpeel-loops -fpeephole -fpeephole2 -fplt
# # -fpredictive-commoning -fprefetch-loop-arrays -free -freg-struct-return
# # -freorder-blocks -freorder-blocks-and-partition -freorder-functions
# # -frerun-cse-after-loop -fsched-critical-path-heuristic
# # -fsched-dep-count-heuristic -fsched-group-heuristic -fsched-interblock
# # -fsched-last-insn-heuristic -fsched-rank-heuristic -fsched-spec
# # -fsched-spec-insn-heuristic -fsched-stalled-insns-dep -fschedule-fusion
# # -fschedule-insns2 -fsemantic-interposition -fshow-column -fshrink-wrap
# # -fshrink-wrap-separate -fsigned-zeros -fsplit-ivs-in-unroller
# # -fsplit-loops -fsplit-paths -fsplit-wide-types -fssa-backprop
# # -fssa-phiopt -fstdarg-opt -fstore-merging -fstrict-aliasing
# # -fstrict-volatile-bitfields -fsync-libcalls -fthread-jumps
# # -ftoplevel-reorder -ftrapping-math -ftree-bit-ccp -ftree-builtin-call-dce
# # -ftree-ccp -ftree-ch -ftree-coalesce-vars -ftree-copy-prop -ftree-cselim
# # -ftree-dce -ftree-dominator-opts -ftree-dse -ftree-forwprop -ftree-fre
# # -ftree-loop-distribute-patterns -ftree-loop-distribution
# # -ftree-loop-if-convert -ftree-loop-im -ftree-loop-ivcanon
# # -ftree-loop-optimize -ftree-loop-vectorize -ftree-parallelize-loops=
# # -ftree-partial-pre -ftree-phiprop -ftree-pre -ftree-pta -ftree-reassoc
# # -ftree-scev-cprop -ftree-sink -ftree-slp-vectorize -ftree-slsr -ftree-sra
# # -ftree-switch-conversion -ftree-tail-merge -ftree-ter -ftree-vrp
# # -funit-at-a-time -funswitch-loops -fverbose-asm -fzero-initialized-in-bss
# # -m128bit-long-double -m64 -m80387 -malign-stringops
# # -mavx256-split-unaligned-load -mavx256-split-unaligned-store
# # -mfancy-math-387 -mfp-ret-in-387 -mfxsr -mieee-fp -mlong-double-80 -mmmx
# # -mno-sse4 -mpush-args -mred-zone -msse -msse2 -mstv -mvzeroupper
#
# 	.text
# 	.section	.rodata.str1.1,"aMS",@progbits,1
# .LC0:
# 	.string	"Thread %d: Count %d\n"
# .LC1:
# 	.string	"Thread %d finished.\n"
# 	.text
# 	.p2align 4,,15
# 	.globl	thread_function
# 	.type	thread_function, @function
# thread_function:
# 	push	rbp	#
# 	mov	rbp, rdi	# arg, arg
# 	push	rbx	#
# 	sub	rsp, 8	#,
# # /tmp/Xd1qj0B_rZ.c:16:     for (int i = 0; i < args->iterations; i++) {
# 	mov	eax, DWORD PTR [rdi+4]	#, MEM[(struct ThreadArgs *)arg_6(D)].iterations
# 	test	eax, eax	#
# 	jle	.L2	#,
# # /tmp/Xd1qj0B_rZ.c:16:     for (int i = 0; i < args->iterations; i++) {
# 	xor	ebx, ebx	# i
# 	.p2align 4,,10
# .L3:
# # /tmp/Xd1qj0B_rZ.c:17:         printf("Thread %d: Count %d\n", args->thread_id, i);
# 	mov	esi, DWORD PTR [rbp+0]	#, MEM[(struct ThreadArgs *)arg_6(D)].thread_id
# 	mov	edx, ebx	#, i
# 	mov	edi, OFFSET FLAT:.LC0	#,
# 	xor	eax, eax	#
# # /tmp/Xd1qj0B_rZ.c:16:     for (int i = 0; i < args->iterations; i++) {
# 	add	ebx, 1	# i,
# # /tmp/Xd1qj0B_rZ.c:17:         printf("Thread %d: Count %d\n", args->thread_id, i);
# 	call	printf	#
# # /tmp/Xd1qj0B_rZ.c:18:         sleep(1); // Sleep for 1 second
# 	mov	edi, 1	#,
# 	call	sleep	#
# # /tmp/Xd1qj0B_rZ.c:16:     for (int i = 0; i < args->iterations; i++) {
# 	cmp	DWORD PTR [rbp+4], ebx	# MEM[(struct ThreadArgs *)arg_6(D)].iterations, i
# 	jg	.L3	#,
# .L2:
# # /tmp/Xd1qj0B_rZ.c:21:     printf("Thread %d finished.\n", args->thread_id);
# 	mov	esi, DWORD PTR [rbp+0]	#, MEM[(struct ThreadArgs *)arg_6(D)].thread_id
# 	mov	edi, OFFSET FLAT:.LC1	#,
# 	xor	eax, eax	#
# 	call	printf	#
# # /tmp/Xd1qj0B_rZ.c:22:     pthread_exit(NULL);
# 	xor	edi, edi	#
# 	call	pthread_exit	#
# 	.size	thread_function, .-thread_function
# 	.section	.rodata.str1.1
# .LC2:
# 	.string	"Failed to create thread 1"
# .LC3:
# 	.string	"Failed to create thread 2"
# 	.section	.rodata.str1.8,"aMS",@progbits,1
# 	.align 8
# .LC4:
# 	.string	"All threads have completed. Exiting."
# 	.section	.text.startup,"ax",@progbits
# 	.p2align 4,,15
# 	.globl	main
# 	.type	main, @function
# main:
# 	push	rbx	#
# # /tmp/Xd1qj0B_rZ.c:31:     if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
# 	xor	esi, esi	#
# 	mov	edx, OFFSET FLAT:thread_function	#,
# # /tmp/Xd1qj0B_rZ.c:27:     struct ThreadArgs args1 = {1, 5};
# 	movabs	rax, 21474836481	# tmp100,
# # /tmp/Xd1qj0B_rZ.c:25: int main() {
# 	sub	rsp, 32	#,
# # /tmp/Xd1qj0B_rZ.c:27:     struct ThreadArgs args1 = {1, 5};
# 	mov	QWORD PTR [rsp+16], rax	# MEM[(int *)&args1], tmp100
# # /tmp/Xd1qj0B_rZ.c:31:     if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
# 	lea	rcx, [rsp+16]	# tmp102,
# # /tmp/Xd1qj0B_rZ.c:28:     struct ThreadArgs args2 = {2, 5};
# 	add	rax, 1	# tmp101,
# # /tmp/Xd1qj0B_rZ.c:31:     if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
# 	mov	rdi, rsp	#,
# # /tmp/Xd1qj0B_rZ.c:28:     struct ThreadArgs args2 = {2, 5};
# 	mov	QWORD PTR [rsp+24], rax	# MEM[(int *)&args2], tmp101
# # /tmp/Xd1qj0B_rZ.c:31:     if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
# 	call	pthread_create	#
# # /tmp/Xd1qj0B_rZ.c:31:     if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
# 	test	eax, eax	# _1
# 	jne	.L12	#,
# # /tmp/Xd1qj0B_rZ.c:37:     if (pthread_create(&thread2, NULL, thread_function, (void*)&args2) != 0) {
# 	lea	rcx, [rsp+24]	# tmp103,
# 	mov	edx, OFFSET FLAT:thread_function	#,
# 	xor	esi, esi	#
# 	lea	rdi, [rsp+8]	# tmp104,
# 	call	pthread_create	#
# 	mov	ebx, eax	# <retval>,
# # /tmp/Xd1qj0B_rZ.c:37:     if (pthread_create(&thread2, NULL, thread_function, (void*)&args2) != 0) {
# 	test	eax, eax	# <retval>
# 	jne	.L13	#,
# # /tmp/Xd1qj0B_rZ.c:43:     pthread_join(thread1, NULL);
# 	mov	rdi, QWORD PTR [rsp]	#, thread1
# 	xor	esi, esi	#
# 	call	pthread_join	#
# # /tmp/Xd1qj0B_rZ.c:44:     pthread_join(thread2, NULL);
# 	mov	rdi, QWORD PTR [rsp+8]	#, thread2
# 	xor	esi, esi	#
# 	call	pthread_join	#
# # /tmp/Xd1qj0B_rZ.c:46:     printf("All threads have completed. Exiting.\n");
# 	mov	edi, OFFSET FLAT:.LC4	#,
# 	call	puts	#
# .L7:
# # /tmp/Xd1qj0B_rZ.c:48: }
# 	add	rsp, 32	#,
# 	mov	eax, ebx	#, <retval>
# 	pop	rbx	#
# 	ret
# .L13:
# # /tmp/Xd1qj0B_rZ.c:38:         perror("Failed to create thread 2");
# 	mov	edi, OFFSET FLAT:.LC3	#,
# # /tmp/Xd1qj0B_rZ.c:39:         return 1;
# 	mov	ebx, 1	# <retval>,
# # /tmp/Xd1qj0B_rZ.c:38:         perror("Failed to create thread 2");
# 	call	perror	#
# # /tmp/Xd1qj0B_rZ.c:39:         return 1;
# 	jmp	.L7	#
# .L12:
# # /tmp/Xd1qj0B_rZ.c:32:         perror("Failed to create thread 1");
# 	mov	edi, OFFSET FLAT:.LC2	#,
# # /tmp/Xd1qj0B_rZ.c:33:         return 1;
# 	mov	ebx, 1	# <retval>,
# # /tmp/Xd1qj0B_rZ.c:32:         perror("Failed to create thread 1");
# 	call	perror	#
# # /tmp/Xd1qj0B_rZ.c:33:         return 1;
# 	jmp	.L7	#
# 	.size	main, .-main
# 	.ident	"GCC: 8.3 [DragonFly] Release/2019-02-22"
# 	.section	.note.GNU-stack,"",@progbits
# Thread 1: Count 0
# Thread 2: Count 0
# Thread 2: Count 1
# Thread 1: Count 1
# Thread 2: Count 2
# Thread 1: Count 2
# Thread 2: Count 3
# Thread 1: Count 3
# Thread 2: Count 4
# Thread 1: Count 4
# Thread 2 finished.
# Thread 1 finished.
# All threads have completed. Exiting.
# /tmp/Xd1qj0B_rZ.c
