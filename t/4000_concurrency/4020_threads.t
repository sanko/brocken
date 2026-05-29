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
subtest 'spawn_thread parsing' => sub {
    my $source = 'spawn_thread sub { print "hi\n"; };';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'parsed program';
    is scalar( @{ $ast->statements } ), 1, 'one statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'statement is Call';
    is $ast->statements->[0]->name,                'spawn_thread', 'call name is spawn_thread';
    is scalar( @{ $ast->statements->[0]->args } ), 1,              'one argument';
    ok $ast->statements->[0]->args->[0]->isa('Brocken::AST::OOP::AnonSub'), 'arg is AnonSub';
};
subtest 'spawn_thread compile and run' => sub {
    my $source = 'print "before\n"; my $t = spawn_thread sub { print "ok\n"; }; print "spawned\n"; join_thread($t); print "after\n";';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    ok $cfg->isa('Brocken::IR::CFG'), 'lowered to CFG';
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $emitter   = $new_emitter->();
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = $selector->data_segment();
    my $exe       = 'thread_test' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    ok -e $exe, 'Executable generated';
    if   ( -e $exe ) { diag "FILE EXISTS: $exe"; }
    else             { diag "FILE DOES NOT EXIST: $exe"; }
    my $prefix = ( $^O eq 'MSWin32' ) ? '.\\' : './';
    my $output = `$prefix$exe`;
    diag $output;
    chomp $output;
    my @lines = split /\n/, $output;
    is $lines[0],  'before', 'first line is before';
    is $lines[-1], 'after',  'last line is after (join_thread waited)';
    ok grep( /^ok$/,      @lines ), 'output contains ok';
    ok grep( /^spawned$/, @lines ), 'output contains spawned';
    my %pos = map { $lines[$_] => $_ } grep { $lines[$_] eq 'ok' || $lines[$_] eq 'after' } 0 .. $#lines;
    ok exists( $pos{ok} ) && exists( $pos{after} ) && $pos{ok} < $pos{after}, 'ok printed before after (join_thread waited)';

    # unlink $exe;
};
subtest 'spawn_thread concurrent execution' => sub {

    # Parent prints 'before'.
    # Parent spawns child:
    #    Child prints 'child_start', sleeps 2s, prints 'child_end', and exits.
    # Parent prints 'parent_mid', sleeps 1s, waits for child, prints 'after'.
    # Expected order: before -> child_start -> parent_mid -> child_end -> after
    my $source
        = 'say "before"; my $t = spawn_thread sub { say "child_start"; sleep(2); say "child_end"; }; sleep (1); say "parent_mid"; sleep(1); join_thread($t); say "after";';
    my $lexer     = Brocken::Lexer->new( source => $source );
    my $parser    = Brocken::Parser->new( lexer => $lexer );
    my $ast       = $parser->parse();
    my $cfg       = $lowerer->lower($ast);
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $emitter   = $new_emitter->();
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = $selector->data_segment();
    my $exe       = 'thread_test_concurrent' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    ok -e $exe, 'Executable generated';
    if   ( -e $exe ) { diag "FILE EXISTS: $exe"; }
    else             { diag "FILE DOES NOT EXIST: $exe"; }
    my $prefix = ( $^O eq 'MSWin32' ) ? '.\\' : './';
    my $output = `$prefix$exe`;
    diag "RAW OUTPUT:\n" . $output;
    $output =~ s/\r\n/\n/g;
    chomp $output;
    my @lines = grep {/\S/} split /\n/, $output;
    diag "PROCESSED LINES: " . join( ", ", @lines );

    # Expected order check
    my %pos = map { $lines[$_] => $_ } 0 .. $#lines;
    ok defined $pos{before},      'found before';
    ok defined $pos{child_start}, 'found child_start';
    ok defined $pos{parent_mid},  'found parent_mid';
    ok defined $pos{child_end},   'found child_end';
    ok defined $pos{after},       'found after';
    if ( defined $pos{before}      && defined $pos{child_start} ) { ok $pos{before} < $pos{child_start},     'before before child_start'; }
    if ( defined $pos{child_start} && defined $pos{parent_mid} )  { ok $pos{child_start} < $pos{parent_mid}, 'child_start before parent_mid'; }
    if ( defined $pos{parent_mid}  && defined $pos{child_end} )   { ok $pos{parent_mid} < $pos{child_end},   'parent_mid before child_end'; }
    if ( defined $pos{child_end}   && defined $pos{after} )       { ok $pos{child_end} < $pos{after},        'child_end before after'; }

    # unlink $exe;
};
done_testing;
