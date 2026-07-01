use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../lib', '../../../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature    qw[class];
use File::Temp qw(tempfile);
#
my ( $fh, $cfile ) = tempfile( SUFFIX => '.c', UNLINK => 0 );
print $fh <<'C';
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

// Structure to pass multiple arguments to the thread
struct ThreadArgs {
    int thread_id;
    int iterations;
};

// The function each thread will run
void* thread_function(void* arg) {
    struct ThreadArgs* args = (struct ThreadArgs*)arg;

    for (int i = 0; i < args->iterations; i++) {
        printf("Thread %d: Count %d\n", args->thread_id, i);
        sleep(1); // Sleep for 1 second
    }

    printf("Thread %d finished.\n", args->thread_id);
    pthread_exit(NULL);
}

int main() {
    pthread_t thread1, thread2;
    struct ThreadArgs args1 = {1, 5};
    struct ThreadArgs args2 = {2, 5};

    // Create Thread 1
    if (pthread_create(&thread1, NULL, thread_function, (void*)&args1) != 0) {
        perror("Failed to create thread 1");
        return 1;
    }

    // Create Thread 2
    if (pthread_create(&thread2, NULL, thread_function, (void*)&args2) != 0) {
        perror("Failed to create thread 2");
        return 1;
    }

    // Wait for both threads to finish
    pthread_join(thread1, NULL);
    pthread_join(thread2, NULL);

    printf("All threads have completed. Exiting.\n");
    return 0;
}
C
diag `gcc -S $cfile`;
diag `gcc -pedantic -Os -std=c99 $cfile -lpthread -o $cfile.exe`;
diag `gcc -S -fverbose-asm -O2 $cfile`;
diag `gcc -fno-asynchronous-unwind-tables -fno-exceptions -fverbose-asm -Wall -Wextra $cfile -O3 -masm=intel -S -o-`;
diag `$cfile.exe`;
diag $cfile;
pass 'cool';
#
done_testing;
__END__
SKIP: {
    skip 'gcc not available', 2 unless system('gcc --version >/dev/null 2>&1') == 0;

    subtest 'FCB layout and pthread basics' => sub {
        my ( $fh, $cfile ) = tempfile( SUFFIX => '.c', UNLINK => 1 );
        print $fh <<'END_C';
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdint.h>

struct fcb {
    uint64_t rbx;
    uint64_t rbp;
    uint64_t self;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
    uint64_t saved_rsp;
    uint64_t parent;
    uint64_t resume_pc;
    uint64_t os_thread;
};

static void print_fcb_layout(void)
{
    printf("=== FCB struct layout ===\n");
    printf("sizeof(struct fcb)   = %zu (expected 80)\n", sizeof(struct fcb));
#define P(n) printf("offsetof("#n") = %zu (expected %d)\n", offsetof(struct fcb, n), (int)(offsetof(struct fcb, n)))
    P(rbx); P(rbp); P(self); P(r13); P(r14); P(r15);
    P(saved_rsp); P(parent); P(resume_pc); P(os_thread);
    printf("alignment = %zu (expected 8)\n", _Alignof(struct fcb));
}

struct thread_arg { int (*func)(int); int val; };
static int worker_impl(int x) { return x + 1; }
static void *thread_routine(void *arg)
{
    struct thread_arg *ta = arg;
    printf("  thread: func(%d) = %d\n", ta->val, ta->func(ta->val));
    return (void*)(intptr_t)ta->func(ta->val);
}

static void test_pthread_create(void)
{
    printf("\n=== pthread_create + function pointer dispatch ===\n");
    struct thread_arg ta = { .func = worker_impl, .val = 41 };
    pthread_t thr;
    int rc = pthread_create(&thr, NULL, thread_routine, &ta);
    if (rc != 0) { printf("  FAIL: pthread_create returned %d\n", rc); return; }
    void *retval;
    pthread_join(thr, &retval);
    int result = (int)(intptr_t)retval;
    printf("  retval = %d (expected 42) %s\n", result, result == 42 ? "OK" : "FAIL");
}

struct basic_arg { int exit_code; };
static void *basic_thread(void *arg)
{
    struct basic_arg *ba = arg;
    printf("  thread exiting with %d\n", ba->exit_code);
    return (void*)(intptr_t)ba->exit_code;
}

static void test_basic_pthread(void)
{
    printf("\n=== basic pthread_create/join ===\n");
    struct basic_arg ba = { .exit_code = 99 };
    pthread_t thr;
    int rc = pthread_create(&thr, NULL, basic_thread, &ba);
    if (rc != 0) { printf("  FAIL: pthread_create returned %d\n", rc); return; }
    void *retval;
    pthread_join(thr, &retval);
    int result = (int)(intptr_t)retval;
    printf("  retval = %d (expected 99) %s\n", result, result == 99 ? "OK" : "FAIL");
}

static void test_stack_ptr(void)
{
    printf("\n=== stack pointer sanity ===\n");
#if defined(__x86_64__)
    void *sp;
    __asm__("movq %%rsp, %0" : "=r"(sp));
    printf("  rsp = %p  %s\n", sp, (uintptr_t)sp < 0x1000 ? "SUSPICIOUSLY LOW" : "OK");
#elif defined(__aarch64__)
    void *sp;
    __asm__("mov %0, sp" : "=r"(sp));
    printf("  sp  = %p  %s\n", sp, (uintptr_t)sp < 0x1000 ? "SUSPICIOUSLY LOW" : "OK");
#endif
}

int main(void)
{
    printf("=== DragonFly BSD FCB layout diagnostics ===\n");
    print_fcb_layout();
    test_basic_pthread();
    test_pthread_create();
    test_stack_ptr();
    printf("=== all diagnostics complete ===\n");
    return 0;
}
END_C
        close $fh;

        my $outfile = "$cfile.out";
        system( 'gcc', '-o', $outfile, $cfile, '-lpthread' );
        if ( $? != 0 ) {
            skip 'failed to compile layout diagnostic', 1;
        }
        else {
            my $output = qx[$outfile 2>/dev/null];
            diag($_) for split /\n/, $output;
            is $? >> 8, 0, 'FCB layout + pthread basics passed';
            unlink $outfile if -f $outfile;
        }

    };

    subtest 'Isolate trampoline simulation' => sub {
        my ( $fh, $cfile ) = tempfile( SUFFIX => '.c', UNLINK => 1 );
        print $fh <<'END_C';
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdint.h>

struct fcb {
    uint64_t rbx;
    uint64_t rbp;
    uint64_t self;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
    uint64_t saved_rsp;
    uint64_t parent;
    uint64_t resume_pc;
    uint64_t os_thread;
};

struct icb {
    uint64_t heap_cursor;
    uint8_t  _pad[56];
};

struct isolate_arg {
    struct fcb *fcb;
    struct icb *icb;
};

static int worker_fn(void) {
    printf("  worker_fn called\n");
    return 42;
}

static void *trampoline(void *arg) {
    struct isolate_arg *ta = arg;
    struct fcb *fcb = ta->fcb;
    struct icb *icb = ta->icb;

    printf("  trampoline: fcb=%p icb=%p\n", (void*)fcb, (void*)icb);

    fcb->os_thread = (uint64_t)(uintptr_t)icb;

    int (*func)(void) = (int (*)(void))(uintptr_t)fcb->resume_pc;
    printf("  trampoline: resume_pc=%p\n", (void*)func);

    int result = func();
    printf("  trampoline: result=%d\n", result);
    return (void*)(intptr_t)result;
}

int main(void) {
    printf("=== Isolate trampoline simulation ===\n");

    struct fcb *fcb = aligned_alloc(16, sizeof(struct fcb));
    struct icb *icb = aligned_alloc(16, sizeof(struct icb));
    if (!fcb || !icb) { printf("FAIL: allocation failed\n"); free(fcb); free(icb); return 1; }

    fcb->rbx       = 0;
    fcb->rbp       = 0;
    fcb->self      = (uint64_t)(uintptr_t)fcb;
    fcb->r13       = 0;
    fcb->r14       = 0;
    fcb->r15       = 0;
    fcb->saved_rsp = 0;
    fcb->parent    = 0;
    fcb->resume_pc = (uint64_t)(uintptr_t)worker_fn;
    fcb->os_thread = (uint64_t)(uintptr_t)icb;

    icb->heap_cursor = 0;

    struct isolate_arg a;
    a.fcb = fcb;
    a.icb = icb;

    pthread_t thr;
    int rc = pthread_create(&thr, NULL, trampoline, &a);
    if (rc != 0) { printf("FAIL: pthread_create returned %d\n", rc); free(fcb); free(icb); return 1; }

    void *retval;
    pthread_join(thr, &retval);
    int result = (int)(intptr_t)retval;
    printf("isolate result = %d (expected 42) %s\n", result, result == 42 ? "OK" : "FAIL");

    free(fcb);
    free(icb);
    return result == 42 ? 0 : 1;
}
END_C
        close $fh;

        my $outfile = "$cfile.out";
        system( 'gcc', '-o', $outfile, $cfile, '-lpthread' );
        if ( $? != 0 ) {
            skip 'failed to compile isolate diagnostic', 1;
        }
        else {
            my $output = qx[$outfile 2>/dev/null];
            diag($_) for split /\n/, $output;
            is $? >> 8, 0, 'isolate trampoline simulation passed';
            unlink $outfile if -f $outfile;
        }

    };
}

SKIP: {
    skip 'objdump not available', 1
        unless system('objdump --version >/dev/null 2>&1') == 0;

    subtest 'Disassemble Brocken isolate functions' => sub {
        my $brocken  = Brocken->new();
        my $platform = $brocken->platform;
        skip 'not native', 1 unless $platform->is_native;

        my $i32 = Brocken::Lindsay::IR::Type::i32();

        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );

        for my $variant ( 1, 2 ) {
            my $with_join = ( $variant == 2 );

            my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
            my $mb   = Brocken::Lindsay::IR::Builder->new();
            $mb->position_at_end( $main->append_block('entry') );
            my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
            $mb->build_isolate_join($iso) if $with_join;
            $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );

            my $funcs      = $brocken->codegen->emit_functions( [ $main, $worker ] );

            # Prepend write('!', 1) syscall to _isolate_trampoline so we can
            # tell whether the new thread starts executing before it crashes.
            for my $f ( $funcs->@* ) {
                next unless $f->{name} eq '_isolate_trampoline';
                my $stub;
                if ( $platform->is_linux ) {
                    $stub = pack 'C*', 0x57,                # push rdi (save arg ptr)
                        0x68,0x21,0,0,0,                   # push 0x21 ('!')
                        0x48,0x89,0xE6,                    # mov rsi, rsp
                        0xBF,1,0,0,0,                       # mov edi, 1
                        0xBA,1,0,0,0,                       # mov edx, 1
                        0xB8,1,0,0,0,                       # mov eax, 1 (SYS_write)
                        0x0F,0x05,                          # syscall
                        0x48,0x83,0xC4,0x08,                # add rsp, 8
                        0x5F;                               # pop rdi (restore arg ptr)
                }
                else {
                    $stub = pack 'C*', 0x57,                # push rdi (save arg ptr)
                        0x68,0x21,0,0,0,                    # push 0x21 ('!')
                        0x48,0x89,0xE6,                     # mov rsi, rsp
                        0xBF,1,0,0,0,                       # mov edi, 1
                        0xBA,1,0,0,0,                       # mov edx, 1
                        0xB8,4,0,0,0,                       # mov eax, 4 (BSD SYS_write)
                        0x0F,0x05,                          # syscall
                        0x48,0x83,0xC4,0x08,                # add rsp, 8
                        0x5F;                               # pop rdi (restore arg ptr)
                }
                $f->{bytes} = $stub . $f->{bytes};
                diag( "  prepended write syscall to _isolate_trampoline (" . length($stub) . " bytes)" );
                last;
            }

            my $output_file = $brocken->tmpdir . '/isolate_diag' . $brocken->ext;
            $brocken->linker->write_executable( $output_file, $funcs, $platform );

            if ( $variant == 1 ) {
                diag( "--- generated function sizes ---" );
                for my $f ( $funcs->@* ) {
                    diag( sprintf "  %-30s %4d bytes", $f->{name}, length( $f->{bytes} // '' ) );
                }

                for my $f ( $funcs->@* ) {
                    my $bytes = $f->{bytes};
                    next unless length $bytes;
                    my ( $fh, $binfile ) = tempfile( SUFFIX => '.bin', UNLINK => 1 );
                    print $fh $bytes;
                    close $fh;
                    my $dis = qx[objdump -D -b binary -m i386:x86-64 -M x86-64 $binfile 2>/dev/null];
                    diag( "" );
                    diag( "--- $f->{name} (".length($bytes)." bytes) ---" );
                    diag( sprintf "  hex: %s", unpack( 'H*', $bytes ) ) if length($bytes) <= 64;
                    for ( split /\n/, $dis ) {
                        next if /^$/ || /file format/ || /^Disassembly/;
                        s/^\s+//;
                        s/\t+/ /g;
                        diag("  $_");
                    }
                }

                diag( "" );
                diag( "--- linked binary .text hex dump ---" );
                my $txth = qx[objdump -s -j .text $output_file 2>/dev/null];
                if ( $? == 0 && $txth !~ /^\s*$/ ) {
                    for ( split /\n/, $txth ) { s/\t+/ /g; diag("  $_"); }
                }

                diag( "" );
                diag( "--- linked binary disassembly (full) ---" );
                my $fulld = qx[objdump -d -M x86-64 $output_file 2>/dev/null];
                if ( $? == 0 && $fulld !~ /^\s*$/ ) {
                    for ( split /\n/, $fulld ) {
                        next if /^$/ || /file format/ || /^Disassembly/;
                        s/\t+/ /g; s/^\s+//;
                        diag("  $_");
                    }
                }

                diag( "" );
                diag( "--- linked binary dynamic relocations ---" );
                my $dynrel = qx[objdump -R $output_file 2>/dev/null];
                if ( $? == 0 && $dynrel !~ /^\s*$/ ) {
                    for ( split /\n/, $dynrel ) { s/\t+/ /g; diag("  $_"); }
                }
                else {
                    diag("  (no dynamic relocations or -R unavailable)");
                }

                diag( "" );
                diag( "--- dynamic section (DT_NEEDED etc) ---" );
                my $dynsec = qx[readelf -d $output_file 2>/dev/null];
                if ( $? == 0 && $dynsec !~ /^\s*$/ ) {
                    for ( split /\n/, $dynsec ) { s/\t+/ /g; diag("  $_"); }
                }
                else {
                    diag("  (readelf -d unavailable)");
                }

                diag( "" );
                diag( "--- program headers (readelf -l) ---" );
                my $phdr = qx[readelf -l $output_file 2>/dev/null];
                if ( $? == 0 && $phdr !~ /^\s*$/ ) {
                    for ( split /\n/, $phdr ) { s/\t+/ /g; diag("  $_"); }
                }
                else {
                    diag("  (readelf -l unavailable)");
                }

                diag( "" );
                diag( "--- GOT section hex dump ---" );
                my $gotdump = qx[objdump -s -j .got $output_file 2>/dev/null];
                if ( $? == 0 && $gotdump !~ /^\s*$/ ) {
                    for ( split /\n/, $gotdump ) { s/\t+/ /g; diag("  $_"); }
                }
                else {
                    diag("  (objdump -s -j .got unavailable)");
                }

                diag( "" );
                diag( "--- dynamic symbol table ---" );
                my $dsym = qx[objdump -T $output_file 2>/dev/null];
                if ( $? == 0 && $dsym !~ /^\s*$/ ) {
                    for ( split /\n/, $dsym ) { s/\t+/ /g; diag("  $_"); }
                }
                else {
                    diag("  (objdump -T unavailable)");
                }

                ok scalar $funcs->@* > 0, 'isolate functions disassembled';
            }

            my $tag = $with_join ? 'create+join' : 'create-only';
            diag( "" );
            diag( "--- running linked binary ($tag) ---" );
            my $run_out = qx[timeout 10 $output_file 2>&1];
            my $run_exit = $? >> 8;
            my $run_sig  = $? & 127;
            if ( $run_sig ) {
                diag( "  KILLED by signal $run_sig" );
                diag( "--- GDB backtrace ($tag) ---" );
                my $gdb_out = qx[gdb -batch -ex run -ex bt -ex 'info registers' $output_file 2>&1];
                for ( split /\n/, $gdb_out ) {
                    s/\t+/ /g; s/^\s+//;
                    next if /^$/ || /no debugging symbols|\.gdbinit/;
                    diag("  $_");
                }
            }
            elsif ( $run_exit == 0 ) {
                diag( "  exit 0 (success)" );
            }
            else {
                diag( "  exit $run_exit" );
            }
            for ( split /\n/, $run_out ) { s/\t+/ /g; diag("  $_"); }
            ok $run_exit == 99 && $run_sig == 0, "$tag binary (exit 99)";

            unlink $output_file;
        }

        diag( "" );
        diag( "=== GCC comparison binary (pthread_create + pthread_join) ===" );
        my $c_src = $brocken->tmpdir . '/pthread_compare.c';
        my $c_out = $brocken->tmpdir . '/pthread_compare' . $brocken->ext;
        open my $cfh, '>', $c_src or die $!;
        print $cfh <<'C_END';
#include <pthread.h>
static void *worker(void *arg) { return arg; }
int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    pthread_join(t, NULL);
    return 0;
}
C_END
        close $cfh;
        if ( system( 'gcc', '-o', $c_out, $c_src, '-lpthread' ) == 0 ) {
            diag( "--- GCC program headers ---" );
            my $gph = qx[readelf -l $c_out 2>/dev/null];
            if ( $? == 0 && $gph !~ /^\s*$/ ) {
                for ( split /\n/, $gph ) { s/\t+/ /g; diag("  $_"); }
            }
            else {
                diag("  (readelf -l unavailable)");
            }
            diag( "--- GCC dynamic section (DT_NEEDED etc) ---" );
            my $dyn = qx[readelf -d $c_out 2>/dev/null];
            if ( $? == 0 && $dyn !~ /^\s*$/ ) {
                for ( split /\n/, $dyn ) { s/\t+/ /g; diag("  $_"); }
            }
            diag( "--- GCC dynamic symbol table ---" );
            my $sym = qx[objdump -T $c_out 2>/dev/null];
            if ( $? == 0 && $sym !~ /^\s*$/ ) {
                for ( split /\n/, $sym ) { s/\t+/ /g; diag("  $_"); }
            }
            unlink $c_out;
        }
        else {
            diag( "  (gcc comparison build failed)" );
        }
        unlink $c_src;


    };
}

SKIP: {
    skip 'objdump not available', 1
        unless system('objdump --version >/dev/null 2>&1') == 0;

    subtest 'Run trivial Brocken binaries' => sub {
        my $brocken  = Brocken->new();
        my $platform = $brocken->platform;
        skip 'not native', 1 unless $platform->is_native;

        my $i32 = Brocken::Lindsay::IR::Type::i32();

        my $trivial = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $b       = Brocken::Lindsay::IR::Builder->new();
        $b->position_at_end( $trivial->append_block('entry') );
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );

        my $funcs = $brocken->codegen->emit_functions( [$trivial] );
        my $output_file = $brocken->tmpdir . '/trivial_diag' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );

        diag( "--- running trivial binary (ret 42) ---" );
        my $out = qx[timeout 10 $output_file 2>&1];
        my $exit = $? >> 8;
        my $sig  = $? & 127;
        diag( $sig ? "  KILLED by signal $sig" : "  exit $exit" );
        for ( split /\n/, $out ) { s/\t+/ /g; diag("  $_"); }
        ok $exit == 42 && $sig == 0, 'trivial binary (ret 42)';

        unlink $output_file;

    };
}

SKIP: {
    skip 'gcc not available', 1 unless system('gcc --version >/dev/null 2>&1') == 0;

    subtest 'C-level pthread_create resolution (dlsym vs direct)' => sub {
        my $brocken = Brocken->new();
        my $cfile = $brocken->tmpdir . '/pthread_resolve.c';
        open my $fh, '>', $cfile or die $!;
        print $fh <<'C_END';
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static void *worker(void *arg) { return arg; }

int main(void) {
    printf("=== pthread_create resolution diagnostic ===\n");

    /* 1. Direct call via PLT (what gcc produces) */
    printf("--- direct pthread_create ---\n");
    pthread_t t1;
    int r1 = pthread_create(&t1, NULL, worker, NULL);
    printf("direct: rc=%d\n", r1);
    if (r1 == 0) {
        void *ret;
        pthread_join(t1, &ret);
        printf("direct: join ok\n");
    }

    /* 2. Call through dlsym(RTLD_DEFAULT, "pthread_create") */
    printf("--- dlsym pthread_create ---\n");
    void *sym = dlsym(RTLD_DEFAULT, "pthread_create");
    printf("dlsym(RTLD_DEFAULT) = %p\n", sym);
    if (sym) {
        int (*fptr)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
            (int (*)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *))sym;
        pthread_t t2;
        int r2 = fptr(&t2, NULL, worker, NULL);
        printf("dlsym'd: rc=%d\n", r2);
        if (r2 == 0) {
            void *ret;
            pthread_join(t2, &ret);
            printf("dlsym'd: join ok\n");
        }
    }
    else {
        printf("dlsym'd: sym is NULL, dlerror=%s\n", dlerror());
    }

    /* 3. Call through dlsym on explicit libpthread handle */
    printf("--- dlopen/dlsym pthread_create ---\n");
    void *lib = dlopen("libpthread.so.0", RTLD_LAZY | RTLD_LOCAL);
    printf("dlopen(libpthread) = %p\n", lib);
    if (lib) {
        void *sym2 = dlsym(lib, "pthread_create");
        printf("dlsym(handle) = %p\n", sym2);
        if (sym2) {
            int (*fptr)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
                (int (*)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *))sym2;
            pthread_t t3;
            int r3 = fptr(&t3, NULL, worker, NULL);
            printf("dlopen/dlsym: rc=%d\n", r3);
            if (r3 == 0) {
                void *ret;
                pthread_join(t3, &ret);
                printf("dlopen/dlsym: join ok\n");
            }
        }
        else {
            printf("dlsym(handle) is NULL, dlerror=%s\n", dlerror());
        }
        dlclose(lib);
    }
    else {
        printf("dlopen failed, dlerror=%s\n", dlerror());
    }

    return 0;
}
C_END
        close $fh;

        my $outfile = "$cfile.out";
        system( 'gcc', '-o', $outfile, $cfile, '-lpthread', '-ldl' );
        if ( $? != 0 ) {
            skip 'failed to compile pthread resolve diagnostic', 1;
        }
        else {
            my $output = qx[$outfile 2>/dev/null];
            diag($_) for split /\n/, $output;
            is $? >> 8, 0, 'pthread_create resolution diagnostic passed';
            unlink $outfile if -f $outfile;
        }

    };
}

SKIP: {
    skip 'gcc not available', 1 unless system('gcc --version >/dev/null 2>&1') == 0;

    subtest 'Isolate trampoline from non-PIE (ET_EXEC) binary' => sub {
        my $brocken = Brocken->new();
        my $cfile = $brocken->tmpdir . '/isolate_nonpie.c';
        open my $fh, '>', $cfile or die $!;
        print $fh <<'C_END';
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdint.h>

struct fcb {
    uint64_t rbx, rbp, self, r13, r14, r15;
    uint64_t saved_rsp, parent, resume_pc, os_thread;
};

struct icb {
    uint64_t heap_cursor;
    uint8_t  _pad[56];
};

struct isolate_arg {
    struct fcb *fcb;
    struct icb *icb;
};

static int worker_fn(void) {
    __asm__ volatile(
        "push $0x21\n"
        "mov %%rsp, %%rsi\n"
        "mov $1, %%edi\n"
        "mov $1, %%edx\n"
#if defined(__DragonFly__)
        "mov $4, %%eax\n"
#else
        "mov $1, %%eax\n"
#endif
        "syscall\n"
        "add $8, %%rsp\n"
        ::: "rax", "rdi", "rsi", "rdx", "memory"
    );
    return 42;
}

static void *trampoline(void *arg) {
    struct isolate_arg *ta = arg;
    struct fcb *fcb = ta->fcb;
    struct icb *icb = ta->icb;
    printf("  trampoline: fcb=%p icb=%p\n", (void*)fcb, (void*)icb);
    int (*func)(void) = (int (*)(void))(uintptr_t)fcb->resume_pc;
    printf("  trampoline: resume_pc=%p\n", (void*)func);
    int result = func();
    printf("  trampoline: result=%d\n", result);
    return (void*)(intptr_t)result;
}

static void run_test(const char *label) {
    struct fcb *fcb = aligned_alloc(16, sizeof(struct fcb));
    struct icb *icb = aligned_alloc(16, sizeof(struct icb));
    if (!fcb || !icb) {
        printf("%s: allocation failed\n", label);
        free(fcb); free(icb); return;
    }
    fcb->rbx = 0; fcb->rbp = 0;
    fcb->self = (uint64_t)(uintptr_t)fcb;
    fcb->r13 = 0; fcb->r14 = 0; fcb->r15 = 0;
    fcb->saved_rsp = 0; fcb->parent = 0;
    fcb->resume_pc = (uint64_t)(uintptr_t)worker_fn;
    fcb->os_thread = (uint64_t)(uintptr_t)icb;
    icb->heap_cursor = 0;
    struct isolate_arg a = { .fcb = fcb, .icb = icb };
    pthread_t thr;
    int rc = pthread_create(&thr, NULL, trampoline, &a);
    if (rc != 0) {
        printf("%s: FAIL pthread_create returned %d\n", label, rc);
        free(fcb); free(icb); return;
    }
    void *retval;
    pthread_join(thr, &retval);
    int result = (int)(intptr_t)retval;
    printf("%s: result=%d %s\n", label, result, result == 42 ? "OK" : "FAIL");
    free(fcb); free(icb);
}

int main(void) {
    printf("=== Isolate trampoline PIE vs non-PIE ===\n");
    printf("\n--- PIE test ---\n");
    run_test("PIE");
    printf("\n--- non-PIE test ---\n");
    run_test("non-PIE");
    return 0;
}
C_END
        close $fh;

        # Compile and run PIE version (gcc default)
        my $out_pie = "$cfile.pie";
        system('gcc', '-o', $out_pie, $cfile, '-lpthread', '-ldl');
        my $rc_pie = $?;
        my $result_pie = -1;
        my $pie_type = '';
        if ($rc_pie == 0) {
            $pie_type = qx[readelf -h $out_pie 2>/dev/null];
            diag("--- PIE binary ELF header ---");
            diag($_) for split /\n/, $pie_type;
            my $output = qx[$out_pie 2>&1];
            $result_pie = $? >> 8;
            my $sig_pie = $? & 127;
            if ($sig_pie) { diag("  PIE KILLED by signal $sig_pie"); }
            diag($_) for split /\n/, $output;
            diag(sprintf("  exit %d", $result_pie));
        }

        # Compile and run non-PIE version
        my $out_nopie = "$cfile.nopie";
        system('gcc', '-no-pie', '-o', $out_nopie, $cfile, '-lpthread', '-ldl');
        my $rc_nopie = $?;
        my $result_nopie = -1;
        my $nopie_type = '';
        if ($rc_nopie == 0) {
            $nopie_type = qx[readelf -h $out_nopie 2>/dev/null];
            diag("--- non-PIE binary ELF header ---");
            diag($_) for split /\n/, $nopie_type;
            my $output = qx[$out_nopie 2>&1];
            $result_nopie = $? >> 8;
            my $sig_nopie = $? & 127;
            if ($sig_nopie) { diag("  non-PIE KILLED by signal $sig_nopie"); }
            diag($_) for split /\n/, $output;
            diag(sprintf("  exit %d", $result_nopie));
        }

        ok $result_pie == 0, "PIE isolate trampoline (exit 0)"
            or diag("PIE: gcc rc=$rc_pie, run rc=$result_pie");
        ok $result_nopie == 0, "non-PIE isolate trampoline (exit 0)"
            or diag("non-PIE: gcc rc=$rc_nopie, run rc=$result_nopie");

        unlink $out_pie if -f $out_pie;
        unlink $out_nopie if -f $out_nopie;
        unlink $cfile;

    };
}

SKIP: {
    skip 'not native x86_64', 1
        unless (Brocken::Katsuro::Platform::parse())->is_x64;

    subtest 'Raw-bytes pthread_create via hand-crafted ELF' => sub {
        my $brocken  = Brocken->new();
        my $platform = $brocken->platform;
        skip 'not native', 1 unless $platform->is_native;

        my $worker_fn = {
            name   => 'worker_fn',
            bytes  => pack('C*', 0xb8, 0x2a, 0, 0, 0,
                                 0xc3),
            fixups => [],
        };

        my $main_bytes = pack('C*',
            0x55,                         # push rbp
            0x48, 0x89, 0xe5,             # mov rbp, rsp
            0x48, 0x83, 0xec, 0x40,       # sub rsp, 0x40
            0x48, 0x8d, 0x7d, 0xf8,       # lea rdi, [rbp-8]   (thr ptr)
            0x31, 0xf6,                   # xor esi, esi       (attr=NULL)
            0x48, 0x8d, 0x15,             # lea rdx, [rip+worker_fn]
            0, 0, 0, 0,                   # placeholder
            0x31, 0xc9,                   # xor ecx, ecx       (arg=NULL)
            0xe8,                         # call pthread_create
            0, 0, 0, 0,                   # placeholder
            0x48, 0x8b, 0x7d, 0xf8,       # mov rdi, [rbp-8]   (thr value)
            0x31, 0xf6,                   # xor esi, esi       (retval=NULL)
            0xe8,                         # call pthread_join
            0, 0, 0, 0,                   # placeholder
            0x31, 0xc0,                   # xor eax, eax       (return 0)
            0xc9,                         # leave
            0xc3,                         # ret
        );

        my $main = {
            name   => 'main',
            bytes  => $main_bytes,
            fixups => [
                { offset => 0x11, type => 'lea_rel32',  target => 'worker_fn' },
                { offset => 0x17, type => 'call_rel32', target => 'pthread_create' },
                { offset => 0x22, type => 'call_rel32', target => 'pthread_join' },
            ],
        };

        my $funcs = [ $main, $worker_fn ];
        my $output_file = $brocken->tmpdir . '/raw_pthread' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );

        diag( "--- running raw-bytes pthread binary ---" );
        my $out = qx[timeout 10 $output_file 2>&1];
        my $exit = $? >> 8;
        my $sig  = $? & 127;
        diag( $sig ? "  KILLED by signal $sig" : "  exit $exit" );
        for ( split /\n/, $out ) { s/\t+/ /g; diag("  $_"); }

        diag( "" );
        diag( "--- raw-bytes binary program headers ---" );
        my $ph = qx[readelf -l $output_file 2>/dev/null];
        if ( $? == 0 && $ph !~ /^\s*$/ ) {
            for ( split /\n/, $ph ) { s/\t+/ /g; diag("  $_"); }
        }
        diag( "--- raw-bytes binary GOT dump ---" );
        my $gd = qx[objdump -s -j .got $output_file 2>/dev/null];
        if ( $? == 0 && $gd !~ /^\s*$/ ) {
            for ( split /\n/, $gd ) { s/\t+/ /g; diag("  $_"); }
        }
        diag( "--- raw-bytes binary dynamic relocations ---" );
        my $dr = qx[objdump -R $output_file 2>/dev/null];
        if ( $? == 0 && $dr !~ /^\s*$/ ) {
            for ( split /\n/, $dr ) { s/\t+/ /g; diag("  $_"); }
        }
        diag( "--- raw-bytes binary dynamic section ---" );
        my $ds = qx[readelf -d $output_file 2>/dev/null];
        if ( $? == 0 && $ds !~ /^\s*$/ ) {
            for ( split /\n/, $ds ) { s/\t+/ /g; diag("  $_"); }
        }
        diag( "--- raw-bytes binary disassembly ---" );
        my $da = qx[objdump -d -M x86-64 $output_file 2>/dev/null];
        if ( $? == 0 && $da !~ /^\s*$/ ) {
            for ( split /\n/, $da ) {
                next if /^$/ || /file format/ || /^Disassembly/;
                s/\t+/ /g; s/^\s+//;
                diag("  $_");
            }
        }

        ok $exit == 0 && $sig == 0, 'raw-bytes pthread_create binary (exit 0)';

        unlink $output_file;

    };
}

done_testing;
