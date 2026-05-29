use Test2::V0;
use lib 'lib', '../../lib';
use Brocken::Target::ABI;
use Brocken::Target::OS;
use Brocken::Compiler::RegisterAllocator;
use Brocken::Compiler::InstructionSelector;
use Brocken::Compiler::Lowerer;
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::IR;
use Brocken::AST;
my $host_os = Brocken::Target::OS->detect_host();
my $os      = $host_os->name;
my $arch    = Brocken::Target::OS->detect_arch();
my $format  = do {
    if    ( $os eq 'win64' ) { require Brocken::Target::Format::PE;    Brocken::Target::Format::PE->new() }
    elsif ( $os eq 'macos' ) { require Brocken::Target::Format::MachO; Brocken::Target::Format::MachO->new() }
    else                     { require Brocken::Target::Format::ELF;   Brocken::Target::Format::ELF->new() }
};
my $abi         = Brocken::Target::ABI->new();
my $lowerer     = Brocken::Compiler::Lowerer->new();
my $new_emitter = sub {
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64;   Brocken::Target::Architecture::ARM64->new( os_name => $os ) }
    elsif ( $arch eq 'riscv64' ) { require Brocken::Target::Architecture::RISCV64; Brocken::Target::Architecture::RISCV64->new() }
    else                         { require Brocken::Target::Architecture::X64;     Brocken::Target::Architecture::X64->new() }
};
my $compile_and_run = sub {
    my ($source) = @_;
    my $lexer    = Brocken::Lexer->new( source => $source );
    my $parser   = Brocken::Parser->new( lexer => $lexer );
    my $ast      = $parser->parse();
    my $cfg      = $lowerer->lower($ast);
    my $alloc    = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping  = $alloc->allocate($cfg);
    my $emitter  = $new_emitter->();
    my $sel      = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text     = $sel->select($cfg);
    my $data     = $sel->data_segment();
    my $exe      = 'test_regr' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    die "Binary not generated" unless -e $exe;
    my $prefix = ( $^O eq 'MSWin32' ) ? '.\\' : './';
    my $output = `$prefix$exe 2>&1`;
    unlink $exe;
    return $output;
};
subtest 'Emitter isolation' => sub {
    my $src1 = 'print "hello";';
    my $src2 = 'print "world";';
    my $out1 = $compile_and_run->($src1);
    my $out2 = $compile_and_run->($src2);
    is $out1, 'hello', 'first program prints hello';
    is $out2, 'world', 'second program prints world (no cross-contamination)';
};
subtest 'Exit terminates program' => sub {
    my $out = $compile_and_run->('print "before"; exit(0); print "after";');
    is $out, 'before', 'exit stops program (after not printed)';
    ok $out !~ /after/, 'after not in output';
};
subtest 'While loop executes body' => sub {
    my $out = $compile_and_run->('my $i = 0; while ($i < 3) { print "x"; $i = $i + 1; }');
    is $out, 'xxx', 'while loop runs 3 iterations';
};
subtest 'Sleep introduces delay' => sub {
    my $start   = time;
    my $out     = $compile_and_run->('sleep(1); print "done";');
    my $elapsed = time - $start;
    ok $elapsed >= 1, "sleep(1) waited at least 1 second (elapsed=$elapsed)";
    is $out, 'done', 'output after sleep';
};
subtest 'For loop basic' => sub {
    my $out = $compile_and_run->('my $i; $i = 0; for ($i = 0; $i < 3; $i = $i + 1) { print "x"; }');
    is $out, 'xxx', 'for loop executes body 3 times';
};
subtest 'Next skips to next iteration' => sub {
    my $out = $compile_and_run->('my $i = 0; while ($i < 3) { $i = $i + 1; if ($i == 2) { next; } print "x"; }');
    is $out, 'xx', 'next skips iteration when i==2';
};
subtest 'Last exits loop early' => sub {
    my $out = $compile_and_run->('my $i = 0; while ($i < 10) { $i = $i + 1; if ($i == 3) { last; } print "x"; }');
    is $out, 'xx', 'last exits after 2 iterations';
};
subtest 'Say appends newline' => sub {
    my $out = $compile_and_run->('say "line1"; say "line2";');
    chomp $out;
    my @lines = split /\n/, $out;
    is $lines[0], 'line1', 'first say line';
    is $lines[1], 'line2', 'second say line';
};
subtest 'Print with explicit newline' => sub {
    my $out = $compile_and_run->('print "a\nb\nc\n";');
    chomp $out;
    my @lines = split /\n/, $out;
    is $lines[0], 'a', 'line a';
    is $lines[1], 'b', 'line b';
    is $lines[2], 'c', 'line c';
};
subtest 'Spawn and join thread' => sub {
    my $out = $compile_and_run->('print "before"; my $t = spawn_thread sub { print "child"; }; join_thread($t); print "after";');
    ok $out =~ /before/, 'before in output';
    ok $out =~ /child/,  'child in output';
    ok $out =~ /after/,  'after in output';
};
subtest 'Concurrent thread with sleep' => sub {
    my $out
        = $compile_and_run->(
        'say "start"; my $t = spawn_thread sub { say "child_start"; sleep(1); say "child_end"; }; say "parent"; sleep(2); join_thread($t); say "done";'
        );
    $out =~ s/\r\n/\n/g;
    chomp $out;
    my @lines = grep {/\S/} split /\n/, $out;
    my %pos   = map  { $lines[$_] => $_ } 0 .. $#lines;
    ok defined $pos{start},       'start present';
    ok defined $pos{child_start}, 'child_start present';
    ok defined $pos{child_end},   'child_end present';
    ok defined $pos{parent},      'parent present';
    ok defined $pos{done},        'done present';
};
subtest 'Unrecognized function call dies' => sub {
    my $source  = 'nonexistent_func(42);';
    my $lexer   = Brocken::Lexer->new( source => $source );
    my $parser  = Brocken::Parser->new( lexer => $lexer );
    my $ast     = $parser->parse();
    my $cfg     = $lowerer->lower($ast);
    my $alloc   = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping = $alloc->allocate($cfg);
    my $emitter = $new_emitter->();
    my $sel     = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    eval { $sel->select($cfg); };
    ok $@, 'unrecognized function call dies';
    like $@, qr/Unimplemented function call/, 'error mentions Unimplemented function call';
};
subtest 'Threading with multiple spawns' => sub {
    my $out
        = $compile_and_run->( 'my $t1 = spawn_thread sub { print "a"; }; ' .
            'my $t2 = spawn_thread sub { print "b"; }; ' .
            'join_thread($t1); join_thread($t2); print "c";' );
    ok length($out) == 3 || length($out) == 3, '3 characters output';
    ok $out =~ /a/, 'a in output';
    ok $out =~ /b/, 'b in output';
    ok $out =~ /c/, 'c in output';
};
subtest 'Redo repeats current iteration' => sub {
    my $out = $compile_and_run->('my $i = 0; while ($i < 3) { $i = $i + 1; if ($i == 2) { redo; } print "x"; }');
    is $out, 'xx', 'redo skips increment step and repeats iteration';
};
done_testing;
