use v5.40;
use Test2::V0;
use File::Temp qw(tempfile);
use lib 'lib', '../lib', 'blib/lib', '../blib/lib';

my $os = $^O;
note("Host OS: $os");

SKIP: {
    skip 'gcc thread disassembly test requires a Unix-like OS with gcc', 1
        if $os eq 'MSWin32' || $os eq 'cygwin';

    my $cc = 'gcc';
    my $cc_ok = system("$cc --version >/dev/null 2>&1");
    skip "gcc not found (tried '$cc')", 1 if $cc_ok != 0;

    # Show GCC target triple
    diag("=== gcc -dumpmachine ===");
    system("$cc -dumpmachine 2>&1");

    # Show preprocessor defines relevant to OS/threads
    diag("=== gcc -dM -E (OS+thread defines) ===");
    system("$cc -lpthread -dM -E -x c /dev/null 2>&1 | grep -iE 'freebsd|dragonfly|linux|gnu|thread|tls|_REENTRANT|_PTHREADS' || true");

    my ($sfh, $c_path) = tempfile('gcc_diag_XXXX', SUFFIX => '.c', TMPDIR => 1, UNLINK => 0);
    my $bin_path = $c_path;
    $bin_path =~ s/\.c$//;
    my $s_path  = $c_path;
    $s_path =~ s/\.c$/.s/;

    my $c_code = <<'CCODE';
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

void* thread_func(void* arg) {
    int* val = (int*)arg;
    printf("thread: %d\n", *val);
    return NULL;
}

int main() {
    pthread_t t;
    int val = 42;
    if (pthread_create(&t, NULL, thread_func, &val) != 0) {
        fprintf(stderr, "pthread_create failed\n");
        return 1;
    }
    if (pthread_join(t, NULL) != 0) {
        fprintf(stderr, "pthread_join failed\n");
        return 1;
    }
    printf("main: ok\n");
    return 0;
}
CCODE

    print $sfh $c_code;
    close $sfh;

    ok(-f $c_path, "C source written: $c_path");

    # ---- Step 1: Assembly dump via gcc -S ----
    note("=== Step 1: gcc -S (assembly output) ===");
    my $asm_out = `$cc -lpthread -S -o $s_path $c_path 2>&1`;
    my $rc1 = $? >> 8;
    if ($rc1 == 0) {
        ok(1, 'gcc -S succeeded');
        open my $afh, '<', $s_path or diag("Cannot read $s_path: $!");
        if ($afh) {
            local $/;
            my $asm = <$afh>;
            close $afh;
            note("Assembly output:\n$asm");
        }
    } else {
        diag("gcc -S failed (exit $rc1): $asm_out");
        ok(0, 'gcc -S succeeded');
    }

    # ---- Step 2: Compile full binary ----
    note("=== Step 2: gcc -o (full binary) ===");
    my $compile = `$cc -lpthread -o $bin_path $c_path 2>&1`;
    my $rc2 = $? >> 8;
    if ($rc2 == 0) {
        ok(1, "gcc compilation succeeded: $bin_path");
    } else {
        diag("gcc compilation failed (exit $rc2): $compile");
        ok(0, 'gcc compilation succeeded');
    }

    # ---- Step 3: Run the binary ----
    note("=== Step 3: Run binary ===");
    my $run = `$bin_path 2>&1`;
    my $rc3 = $? >> 8;
    diag("Binary output: $run");
    diag("Exit code: $rc3");
    if ($rc3 == 0) {
        ok(1, 'Binary execution succeeded');
    } else {
        diag('Binary execution FAILED');
        ok(0, 'Binary execution succeeded');
    }

    # ---- Step 4: ELF dump (program headers, dynamic section, section headers) ----
    note("=== Step 4: ELF Information ===");
    my $elf_ok = 0;
    if (system('readelf --version >/dev/null 2>&1') == 0) {
        $elf_ok = 1;
        diag("=== readelf -h (ELF header) ===");
        system("readelf -h $bin_path 2>&1");
        diag("=== readelf -l (program headers) ===");
        system("readelf -l $bin_path 2>&1");
        diag("=== readelf -d (dynamic section) ===");
        system("readelf -d $bin_path 2>&1");
        diag("=== readelf -S (section headers) ===");
        system("readelf -S $bin_path 2>&1");
        diag("=== readelf -n (notes) ===");
        system("readelf -n $bin_path 2>&1");
        diag("=== readelf -r (relocations) ===");
        system("readelf -r $bin_path 2>&1");
        diag("=== readelf -s (symbol table) ===");
        system("readelf -s $bin_path 2>&1");
    } elsif (system('objdump --version >/dev/null 2>&1') == 0) {
        $elf_ok = 1;
        diag("=== objdump -p (private/dynamic) ===");
        system("objdump -p $bin_path 2>&1");
        diag("=== objdump -h (section headers) ===");
        system("objdump -h $bin_path 2>&1");
        diag("=== objdump -d (disassembly) ===");
        system("objdump -d $bin_path 2>&1");
        diag("=== objdump -R (relocations) ===");
        system("objdump -R $bin_path 2>&1");
        diag("=== objdump -t (symbol table) ===");
        system("objdump -t $bin_path 2>&1");
    } else {
        diag('No readelf or objdump available');
    }
    ok($elf_ok, 'ELF dump completed');

    # ---- Step 5: Hex dump of raw binary ----
    note("=== Step 5: Hex dump ===");
    open my $bfh, '<:raw', $bin_path or do {
        diag("Cannot open $bin_path for reading: $!");
        skip 'Cannot read binary', 1;
    };
    my $bin;
    {
        local $/;
        $bin = <$bfh>;
    }
    close $bfh;

    my $len = length($bin);
    my $dump_max = $len > 8192 ? 8192 : $len;
    diag("Binary size: $len bytes, dumping first $dump_max bytes");

    for (my $i = 0; $i < $dump_max; $i += 16) {
        my $chunk = substr($bin, $i, 16);
        my $hex;
        my $ascii = '';
        my $chunk_len = length($chunk);
        for my $j (0 .. $chunk_len - 1) {
            my $byte = ord(substr($chunk, $j, 1));
            $hex .= sprintf('%02x', $byte);
            if    ($j == $chunk_len - 1) { }               # last byte - no trailing space
            elsif ($j == 7)              { $hex .= '  '; } # group gap - two spaces
            else                         { $hex .= ' ';  } # normal separator
            $ascii .= ($byte >= 32 && $byte < 127) ? chr($byte) : '.';
        }
        diag(sprintf "%08x  %-48s  |%s|", $i, $hex, $ascii);
    }
    ok(1, 'Hex dump completed');

    # ---- Cleanup ----
    note("=== Cleanup ===");
    for my $f ($c_path, $s_path, $bin_path) {
        unlink $f if defined $f && -f $f;
    }
    note('Temporary files removed');
}

done_testing;
